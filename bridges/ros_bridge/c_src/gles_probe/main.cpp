// gles_probe: benchmarks GLES 3.1 compute on the target GPU (ALU, streaming
// bandwidth, block-matching stereo). Not part of the firmware; see the Makefile.
// Block matching has no SGM path aggregation, so its figure is an upper bound.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

namespace {

double now_ms() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

// Headless: Mesa's surfaceless platform, else the default display, which at
// least fails with a clear error.
EGLDisplay open_display() {
  const char* client_extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
  if (client_extensions) std::printf("EGL client extensions: %s\n\n", client_extensions);

  auto get_platform_display =
      reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));

  if (get_platform_display && client_extensions &&
      std::strstr(client_extensions, "EGL_MESA_platform_surfaceless")) {
    EGLDisplay display = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                              EGL_DEFAULT_DISPLAY, nullptr);
    if (display != EGL_NO_DISPLAY) {
      std::printf("display: surfaceless (EGL_MESA_platform_surfaceless)\n");
      return display;
    }
  }

  std::printf("display: EGL_DEFAULT_DISPLAY (surfaceless unavailable)\n");
  return eglGetDisplay(EGL_DEFAULT_DISPLAY);
}

bool init_egl(EGLDisplay* out_display, EGLContext* out_context) {
  EGLDisplay display = open_display();
  if (display == EGL_NO_DISPLAY) {
    std::fprintf(stderr, "gles_probe: no EGL display\n");
    return false;
  }

  EGLint major = 0, minor = 0;
  if (!eglInitialize(display, &major, &minor)) {
    std::fprintf(stderr, "gles_probe: eglInitialize failed (0x%x)\n", eglGetError());
    return false;
  }
  std::printf("EGL %d.%d — %s\n", major, minor, eglQueryString(display, EGL_VENDOR));

  if (!eglBindAPI(EGL_OPENGL_ES_API)) {
    std::fprintf(stderr, "gles_probe: eglBindAPI failed\n");
    return false;
  }

  // ES3 bit is what gates compute-capable contexts.
  const EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                 EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                 EGL_NONE};
  EGLConfig config;
  EGLint num_configs = 0;
  if (!eglChooseConfig(display, config_attributes, &config, 1, &num_configs) ||
      num_configs < 1) {
    std::fprintf(stderr, "gles_probe: no ES3-capable EGLConfig\n");
    return false;
  }

  const EGLint context_attributes[] = {EGL_CONTEXT_MAJOR_VERSION, 3,
                                  EGL_CONTEXT_MINOR_VERSION, 1,
                                  EGL_NONE};
  EGLContext context =
      eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
  if (context == EGL_NO_CONTEXT) {
    std::fprintf(stderr,
                 "gles_probe: no GLES 3.1 context (0x%x) — compute shaders "
                 "need 3.1\n",
                 eglGetError());
    return false;
  }

  // Surfaceless: no draw surface at all. Compute needs none.
  if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
    std::fprintf(stderr, "gles_probe: eglMakeCurrent failed (0x%x)\n", eglGetError());
    return false;
  }

  *out_display = display;
  *out_context = context;
  return true;
}

// Any GL error invalidates the timing that follows it — a rejected
// dispatch takes ~0 ms and reports an absurd throughput, which is worse
// than no measurement at all. Every benchmark checks before reporting.
bool gl_ok(const char* label) {
  GLenum error = glGetError();
  if (error == GL_NO_ERROR) return true;
  std::fprintf(stderr, "gles_probe: %s: GL error 0x%x — result discarded\n",
               label, error);
  return false;
}

GLuint build_compute_program(const char* source, const char* label) {
  GLuint shader = glCreateShader(GL_COMPUTE_SHADER);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);

  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[4096] = {0};
    glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
    std::fprintf(stderr, "gles_probe: %s failed to compile:\n%s\n", label, log);
    return 0;
  }

  GLuint program = glCreateProgram();
  glAttachShader(program, shader);
  glLinkProgram(program);
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[4096] = {0};
    glGetProgramInfoLog(program, sizeof(log) - 1, nullptr, log);
    std::fprintf(stderr, "gles_probe: %s failed to link:\n%s\n", label, log);
    return 0;
  }
  glDeleteShader(shader);
  return program;
}

// One warm-up dispatch, then wall-clock `runs` between glFinish calls: timer
// queries are an optional extension on this driver.
double time_dispatches(GLuint program, GLuint groups_x, GLuint groups_y, int runs) {
  glUseProgram(program);
  glDispatchCompute(groups_x, groups_y, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  glFinish();

  const double start = now_ms();
  for (int i = 0; i < runs; ++i) {
    glDispatchCompute(groups_x, groups_y, 1);
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  }
  glFinish();
  return (now_ms() - start) / runs;
}

const char* kAluSource = R"(#version 310 es
layout(local_size_x = 64) in;
layout(std430, binding = 0) buffer Out { float v[]; };
uniform int uIterations;
void main() {
  uint i = gl_GlobalInvocationID.x;
  float b = 1.0000001, c = 0.9999999;
  // Four independent chains: V3D needs instruction-level parallelism, and
  // fewer chains only measure FMA latency.
  float a0 = float(i) * 1.0e-3, a1 = float(i) * 2.0e-3;
  float a2 = float(i) * 3.0e-3, a3 = float(i) * 4.0e-3;
  for (int k = 0; k < uIterations; ++k) {
    a0 = a0 * b + c;
    a1 = a1 * c + b;
    a2 = a2 * b + c;
    a3 = a3 * c + b;
  }
  v[i] = a0 + a1 + a2 + a3;
}
)";

void benchmark_alu() {
  GLuint program = build_compute_program(kAluSource, "alu");
  if (!program) return;

  const GLuint groups = 4096;
  const GLuint invocations = groups * 64;
  const int iterations = 1000;

  GLuint ssbo;
  glGenBuffers(1, &ssbo);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
  glBufferData(GL_SHADER_STORAGE_BUFFER, invocations * sizeof(float), nullptr,
               GL_DYNAMIC_COPY);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);

  glUseProgram(program);
  glUniform1i(glGetUniformLocation(program, "uIterations"), iterations);

  const double dispatch_ms = time_dispatches(program, groups, 1, 20);
  // 4 FMAs per iteration, 2 flops per FMA.
  const double flops = double(invocations) * double(iterations) * 8.0;
  if (gl_ok("alu")) {
    std::printf("  ALU        %8.3f ms/dispatch   %7.2f GFLOPS (fp32 FMA)\n", dispatch_ms,
                flops / (dispatch_ms * 1.0e6));
  }

  glDeleteBuffers(1, &ssbo);
  glDeleteProgram(program);
}

const char* kCopySource = R"(#version 310 es
layout(local_size_x = 64) in;
layout(std430, binding = 0) readonly  buffer In  { uvec4 src[]; };
layout(std430, binding = 1) writeonly buffer Out { uvec4 dst[]; };
void main() { dst[gl_GlobalInvocationID.x] = src[gl_GlobalInvocationID.x]; }
)";

void benchmark_copy() {
  GLuint program = build_compute_program(kCopySource, "copy");
  if (!program) return;

  const size_t vector_count = 1u * 1024u * 1024u;
  const size_t bytes = vector_count * 16;

  GLuint buffers[2];
  glGenBuffers(2, buffers);
  for (int i = 0; i < 2; ++i) {
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[i]);
    glBufferData(GL_SHADER_STORAGE_BUFFER, bytes, nullptr, GL_DYNAMIC_COPY);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, i, buffers[i]);
  }
  if (!gl_ok("copy: allocation")) {
    glDeleteBuffers(2, buffers);
    glDeleteProgram(program);
    return;
  }

  const double dispatch_ms = time_dispatches(program, vector_count / 64, 1, 20);
  const double gigabytes_moved = double(bytes * 2) / 1.0e9;  // read + write
  if (gl_ok("copy") && dispatch_ms > 0.001) {
    std::printf("  Copy       %8.3f ms/dispatch   %7.2f GB/s (%zu MiB moved)\n",
                dispatch_ms, gigabytes_moved / (dispatch_ms / 1000.0), (bytes * 2) / (1024 * 1024));
  }

  glDeleteBuffers(2, buffers);
  glDeleteProgram(program);
}

// Per pixel: SAD over a (2r+1)² window for each disparity, best wins. Clamped
// rather than border-skipped, so every invocation does the same work.
const char* kStereoSource = R"(#version 310 es
layout(local_size_x = 16, local_size_y = 16) in;
layout(binding = 0) uniform highp usampler2D uLeft;
layout(binding = 1) uniform highp usampler2D uRight;
layout(std430, binding = 2) writeonly buffer Out { uint disp[]; };
uniform int uWidth;
uniform int uHeight;
uniform int uDisparities;
uniform int uWindowRadius;
void main() {
  ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
  if (pixel.x >= uWidth || pixel.y >= uHeight) return;

  ivec2 last = ivec2(uWidth - 1, uHeight - 1);
  uint bestSad = 0xffffffffu;
  int bestDisparity = 0;
  for (int d = 0; d < uDisparities; ++d) {
    uint sad = 0u;
    for (int dy = -uWindowRadius; dy <= uWindowRadius; ++dy) {
      for (int dx = -uWindowRadius; dx <= uWindowRadius; ++dx) {
        ivec2 leftPixel = clamp(ivec2(pixel.x + dx, pixel.y + dy), ivec2(0), last);
        ivec2 rightPixel = clamp(ivec2(pixel.x + dx - d, pixel.y + dy), ivec2(0), last);
        int leftValue = int(texelFetch(uLeft, leftPixel, 0).r);
        int rightValue = int(texelFetch(uRight, rightPixel, 0).r);
        sad += uint(abs(leftValue - rightValue));
      }
    }
    if (sad < bestSad) { bestSad = sad; bestDisparity = d; }
  }
  disp[pixel.y * uWidth + pixel.x] = uint(bestDisparity);
}
)";

GLuint make_gray_texture(int width, int height, unsigned seed) {
  std::vector<uint8_t> pixels(size_t(width) * size_t(height));
  // Deterministic pseudo-texture. Flat images would let the cost
  // comparison exit early in a way real scenes do not.
  unsigned state = seed;
  for (auto& pixel : pixels) {
    state = state * 1664525u + 1013904223u;
    pixel = uint8_t(state >> 24);
  }

  GLuint texture;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8UI, width, height, 0, GL_RED_INTEGER,
               GL_UNSIGNED_BYTE, pixels.data());
  return texture;
}

void benchmark_stereo(int width, int height, int disparities, int window_radius) {
  GLuint program = build_compute_program(kStereoSource, "stereo");
  if (!program) return;

  GLuint left = make_gray_texture(width, height, 12345u);
  GLuint right = make_gray_texture(width, height, 54321u);

  GLuint ssbo;
  glGenBuffers(1, &ssbo);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
  glBufferData(GL_SHADER_STORAGE_BUFFER, size_t(width) * size_t(height) * sizeof(GLuint),
               nullptr, GL_DYNAMIC_COPY);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, ssbo);

  glUseProgram(program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, left);
  glUniform1i(glGetUniformLocation(program, "uLeft"), 0);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, right);
  glUniform1i(glGetUniformLocation(program, "uRight"), 1);
  glUniform1i(glGetUniformLocation(program, "uWidth"), width);
  glUniform1i(glGetUniformLocation(program, "uHeight"), height);
  glUniform1i(glGetUniformLocation(program, "uDisparities"), disparities);
  glUniform1i(glGetUniformLocation(program, "uWindowRadius"), window_radius);

  const GLuint groups_x = GLuint((width + 15) / 16), groups_y = GLuint((height + 15) / 16);
  if (!gl_ok("stereo: setup")) {
    glDeleteProgram(program);
    return;
  }
  const double frame_ms = time_dispatches(program, groups_x, groups_y, 5);
  if (!gl_ok("stereo")) {
    glDeleteProgram(program);
    return;
  }

  const int side = 2 * window_radius + 1;
  const double window = double(side) * double(side);
  const double samples = double(width) * double(height) * double(disparities) * window;
  std::printf(
      "  Stereo     %8.3f ms/frame      %7.2f Msamples/s   (%dx%d, D=%d, "
      "%dx%d window, %.1f Hz)\n",
      frame_ms, samples / (frame_ms * 1000.0), width, height, disparities, side, side,
      1000.0 / frame_ms);

  glDeleteBuffers(1, &ssbo);
  glDeleteTextures(1, &left);
  glDeleteTextures(1, &right);
  glDeleteProgram(program);
}

void print_limits() {
  GLint limit = 0;
  std::printf("GL_VENDOR    %s\n", glGetString(GL_VENDOR));
  std::printf("GL_RENDERER  %s\n", glGetString(GL_RENDERER));
  std::printf("GL_VERSION   %s\n", glGetString(GL_VERSION));
  std::printf("GLSL         %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));

  glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &limit);
  std::printf("max work group invocations   %d\n", limit);
  glGetIntegerv(GL_MAX_COMPUTE_SHARED_MEMORY_SIZE, &limit);
  std::printf("max shared memory            %d bytes\n", limit);
  glGetIntegerv(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &limit);
  std::printf("max SSBO block               %d bytes\n", limit);
  for (int i = 0; i < 3; ++i) {
    GLint size = 0;
    glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, i, &size);
    std::printf("max work group size[%d]       %d\n", i, size);
  }
  std::printf("\n");
}

}  // namespace

int main(int argc, char** argv) {
  const int width = argc > 1 ? std::atoi(argv[1]) : 640;
  const int height = argc > 2 ? std::atoi(argv[2]) : 480;
  const int disparities = argc > 3 ? std::atoi(argv[3]) : 96;
  const int window_radius = argc > 4 ? std::atoi(argv[4]) : 2;

  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  if (!init_egl(&display, &context)) return 1;

  print_limits();

  std::printf("benchmarks (lower ms is better)\n");
  benchmark_alu();
  benchmark_copy();
  benchmark_stereo(width, height, disparities, window_radius);

  std::printf(
      "\nreference points for interpretation:\n"
      "  VideoCore VII peak fp32 @800MHz ....... 76.8 GFLOPS\n"
      "  SoC memory interface (shared w/ CPU) ... 17 GB/s\n"
      "  4x Cortex-A76 @2.4GHz NEON peak fp32 ... ~150 GFLOPS\n"
      "  (the Stereo row is block matching, not SGM: no path aggregation,\n"
      "   so it is an upper bound on a GPU SGM port, not a prediction)\n");

  eglDestroyContext(display, context);
  eglTerminate(display);
  return 0;
}
