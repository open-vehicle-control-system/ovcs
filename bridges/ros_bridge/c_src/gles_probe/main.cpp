// gles_probe: measures what the Pi 5's VideoCore VII can actually do
// with GLES 3.1 compute shaders, so the "should we move SGBM to the
// GPU?" question can be answered with numbers from this board rather
// than with vendor peak figures.
//
// Not part of the firmware — build it with the Nerves sysroot, copy it
// to /data on the device, run it, read the numbers, delete it. See the
// Makefile in this directory.
//
// Three measurements:
//
//   1. ALU     — dependent FMA chains in registers. Approaches the
//                shader core's arithmetic ceiling. Compare against the
//                76.8 GFLOPS quoted for VideoCore VII at 800 MHz.
//   2. Copy    — streaming SSBO read+write. Compare against the 17 GB/s
//                the LPDDR4X interface provides *for the whole SoC* —
//                the CPU is contending for the same budget.
//   3. Stereo  — a block-matching disparity sweep shaped like the real
//                workload: W×H×D SAD over a (2r+1)² window, winner
//                takes all.
//
// A caveat on (3), because it is the number that will get quoted: this
// is block matching, NOT semi-global matching. It has no path
// aggregation, which is the expensive and hard-to-parallelise half of
// SGBM. Treat it as an upper bound on what a GPU port could reach —
// real SGM on this GPU will be slower than this, not faster.

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

// ── EGL bring-up (headless) ─────────────────────────────────────────
// No display, no window: the surfaceless platform is what Mesa offers
// for exactly this. Falls back to the default display if the extension
// is missing, which at least produces a clear error rather than a
// segfault.
EGLDisplay open_display() {
  const char* client_exts = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
  if (client_exts) std::printf("EGL client extensions: %s\n\n", client_exts);

  auto get_platform_display =
      reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));

  if (get_platform_display && client_exts &&
      std::strstr(client_exts, "EGL_MESA_platform_surfaceless")) {
    EGLDisplay d = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                        EGL_DEFAULT_DISPLAY, nullptr);
    if (d != EGL_NO_DISPLAY) {
      std::printf("display: surfaceless (EGL_MESA_platform_surfaceless)\n");
      return d;
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
  const EGLint config_attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                 EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                 EGL_NONE};
  EGLConfig config;
  EGLint num_configs = 0;
  if (!eglChooseConfig(display, config_attrs, &config, 1, &num_configs) ||
      num_configs < 1) {
    std::fprintf(stderr, "gles_probe: no ES3-capable EGLConfig\n");
    return false;
  }

  const EGLint context_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3,
                                  EGL_CONTEXT_MINOR_VERSION, 1,
                                  EGL_NONE};
  EGLContext context =
      eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
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
  GLenum err = glGetError();
  if (err == GL_NO_ERROR) return true;
  std::fprintf(stderr, "gles_probe: %s: GL error 0x%x — result discarded\n",
               label, err);
  return false;
}

// ── shader plumbing ─────────────────────────────────────────────────
GLuint build_compute(const char* source, const char* label) {
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

// Dispatch once to warm up (shader upload, buffer residency), then time
// `runs` dispatches with a glFinish around them. glFinish is the blunt
// instrument, but timer queries are an optional extension on this
// driver and a wall clock across many dispatches is accurate enough for
// a decision this coarse.
double time_dispatches(GLuint program, GLuint gx, GLuint gy, int runs) {
  glUseProgram(program);
  glDispatchCompute(gx, gy, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  glFinish();

  const double start = now_ms();
  for (int i = 0; i < runs; ++i) {
    glDispatchCompute(gx, gy, 1);
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  }
  glFinish();
  return (now_ms() - start) / runs;
}

// ── 1. ALU ceiling ──────────────────────────────────────────────────
const char* kAluSource = R"(#version 310 es
layout(local_size_x = 64) in;
layout(std430, binding = 0) buffer Out { float v[]; };
uniform int uIters;
void main() {
  uint i = gl_GlobalInvocationID.x;
  // Two dependent chains so the compiler cannot collapse them, and
  // enough independence to keep the pipeline fed.
  float b = 1.0000001, c = 0.9999999;
  // Four independent chains: V3D needs instruction-level parallelism to
  // fill its pipeline, and two dependent chains only measure FMA
  // latency.
  float a0 = float(i) * 1.0e-3, a1 = float(i) * 2.0e-3;
  float a2 = float(i) * 3.0e-3, a3 = float(i) * 4.0e-3;
  for (int k = 0; k < uIters; ++k) {
    a0 = a0 * b + c;
    a1 = a1 * c + b;
    a2 = a2 * b + c;
    a3 = a3 * c + b;
  }
  v[i] = a0 + a1 + a2 + a3;
}
)";

void bench_alu() {
  GLuint program = build_compute(kAluSource, "alu");
  if (!program) return;

  const GLuint groups = 4096;      // 4096 × 64 = 262144 invocations
  const GLuint invocations = groups * 64;
  const int iters = 1000;

  GLuint ssbo;
  glGenBuffers(1, &ssbo);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
  glBufferData(GL_SHADER_STORAGE_BUFFER, invocations * sizeof(float), nullptr,
               GL_DYNAMIC_COPY);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);

  glUseProgram(program);
  glUniform1i(glGetUniformLocation(program, "uIters"), iters);

  const double ms = time_dispatches(program, groups, 1, 20);
  // 4 FMAs per iteration, 2 flops per FMA.
  const double flops = double(invocations) * double(iters) * 8.0;
  if (gl_ok("alu")) {
    std::printf("  ALU        %8.3f ms/dispatch   %7.2f GFLOPS (fp32 FMA)\n", ms,
                flops / (ms * 1.0e6));
  }

  glDeleteBuffers(1, &ssbo);
  glDeleteProgram(program);
}

// ── 2. Streaming bandwidth ──────────────────────────────────────────
const char* kCopySource = R"(#version 310 es
layout(local_size_x = 64) in;
layout(std430, binding = 0) readonly  buffer In  { uvec4 src[]; };
layout(std430, binding = 1) writeonly buffer Out { uvec4 dst[]; };
void main() { dst[gl_GlobalInvocationID.x] = src[gl_GlobalInvocationID.x]; }
)";

void bench_copy() {
  GLuint program = build_compute(kCopySource, "copy");
  if (!program) return;

  const size_t vec_count = 1u * 1024u * 1024u;  // 16 MiB in, 16 MiB out
  const size_t bytes = vec_count * 16;

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

  const double ms = time_dispatches(program, vec_count / 64, 1, 20);
  const double gb = double(bytes * 2) / 1.0e9;  // read + write
  if (gl_ok("copy") && ms > 0.001) {
    std::printf("  Copy       %8.3f ms/dispatch   %7.2f GB/s (%zu MiB moved)\n",
                ms, gb / (ms / 1000.0), (bytes * 2) / (1024 * 1024));
  }

  glDeleteBuffers(2, buffers);
  glDeleteProgram(program);
}

// ── 3. Stereo block matching ────────────────────────────────────────
// Shaped like the real workload: for each pixel, sweep D disparities,
// SAD over a (2r+1)² window, keep the best. Coordinates are clamped
// rather than branch-skipped so every invocation does the same work —
// a real kernel would skip the left border, which only makes it
// cheaper.
const char* kStereoSource = R"(#version 310 es
layout(local_size_x = 16, local_size_y = 16) in;
layout(binding = 0) uniform highp usampler2D uLeft;
layout(binding = 1) uniform highp usampler2D uRight;
layout(std430, binding = 2) writeonly buffer Out { uint disp[]; };
uniform int uW;
uniform int uH;
uniform int uD;
uniform int uR;
void main() {
  ivec2 p = ivec2(gl_GlobalInvocationID.xy);
  if (p.x >= uW || p.y >= uH) return;

  uint best = 0xffffffffu;
  int bestd = 0;
  for (int d = 0; d < uD; ++d) {
    uint sad = 0u;
    for (int dy = -uR; dy <= uR; ++dy) {
      for (int dx = -uR; dx <= uR; ++dx) {
        ivec2 lp = clamp(ivec2(p.x + dx, p.y + dy), ivec2(0), ivec2(uW - 1, uH - 1));
        ivec2 rp = clamp(ivec2(p.x + dx - d, p.y + dy), ivec2(0), ivec2(uW - 1, uH - 1));
        int l = int(texelFetch(uLeft, lp, 0).r);
        int r = int(texelFetch(uRight, rp, 0).r);
        sad += uint(abs(l - r));
      }
    }
    if (sad < best) { best = sad; bestd = d; }
  }
  disp[p.y * uW + p.x] = uint(bestd);
}
)";

GLuint make_gray_texture(int w, int h, unsigned seed) {
  std::vector<uint8_t> pixels(size_t(w) * size_t(h));
  // Deterministic pseudo-texture. Flat images would let the cost
  // comparison exit early in a way real scenes do not.
  unsigned state = seed;
  for (auto& px : pixels) {
    state = state * 1664525u + 1013904223u;
    px = uint8_t(state >> 24);
  }

  GLuint tex;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8UI, w, h, 0, GL_RED_INTEGER,
               GL_UNSIGNED_BYTE, pixels.data());
  return tex;
}

void bench_stereo(int w, int h, int d, int r) {
  GLuint program = build_compute(kStereoSource, "stereo");
  if (!program) return;

  GLuint left = make_gray_texture(w, h, 12345u);
  GLuint right = make_gray_texture(w, h, 54321u);

  GLuint ssbo;
  glGenBuffers(1, &ssbo);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
  glBufferData(GL_SHADER_STORAGE_BUFFER, size_t(w) * size_t(h) * sizeof(GLuint),
               nullptr, GL_DYNAMIC_COPY);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, ssbo);

  glUseProgram(program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, left);
  glUniform1i(glGetUniformLocation(program, "uLeft"), 0);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, right);
  glUniform1i(glGetUniformLocation(program, "uRight"), 1);
  glUniform1i(glGetUniformLocation(program, "uW"), w);
  glUniform1i(glGetUniformLocation(program, "uH"), h);
  glUniform1i(glGetUniformLocation(program, "uD"), d);
  glUniform1i(glGetUniformLocation(program, "uR"), r);

  const GLuint gx = GLuint((w + 15) / 16), gy = GLuint((h + 15) / 16);
  if (!gl_ok("stereo: setup")) {
    glDeleteProgram(program);
    return;
  }
  const double ms = time_dispatches(program, gx, gy, 5);
  if (!gl_ok("stereo")) {
    glDeleteProgram(program);
    return;
  }

  const int side = 2 * r + 1;
  const double window = double(side) * double(side);
  const double samples = double(w) * double(h) * double(d) * window;
  std::printf(
      "  Stereo     %8.3f ms/frame      %7.2f Msamples/s   (%dx%d, D=%d, "
      "%dx%d window, %.1f Hz)\n",
      ms, samples / (ms * 1000.0), w, h, d, side, side, 1000.0 / ms);

  glDeleteBuffers(1, &ssbo);
  glDeleteTextures(1, &left);
  glDeleteTextures(1, &right);
  glDeleteProgram(program);
}

void print_limits() {
  GLint v = 0;
  std::printf("GL_VENDOR    %s\n", glGetString(GL_VENDOR));
  std::printf("GL_RENDERER  %s\n", glGetString(GL_RENDERER));
  std::printf("GL_VERSION   %s\n", glGetString(GL_VERSION));
  std::printf("GLSL         %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));

  glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &v);
  std::printf("max work group invocations   %d\n", v);
  glGetIntegerv(GL_MAX_COMPUTE_SHARED_MEMORY_SIZE, &v);
  std::printf("max shared memory            %d bytes\n", v);
  glGetIntegerv(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &v);
  std::printf("max SSBO block               %d bytes\n", v);
  for (int i = 0; i < 3; ++i) {
    GLint size = 0;
    glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, i, &size);
    std::printf("max work group size[%d]       %d\n", i, size);
  }
  std::printf("\n");
}

}  // namespace

int main(int argc, char** argv) {
  const int w = argc > 1 ? std::atoi(argv[1]) : 640;
  const int h = argc > 2 ? std::atoi(argv[2]) : 480;
  const int d = argc > 3 ? std::atoi(argv[3]) : 96;
  const int r = argc > 4 ? std::atoi(argv[4]) : 2;  // 5x5 window

  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  if (!init_egl(&display, &context)) return 1;

  print_limits();

  std::printf("benchmarks (lower ms is better)\n");
  bench_alu();
  bench_copy();
  bench_stereo(w, h, d, r);

  std::printf(
      "\nreference points for interpretation:\n"
      "  VideoCore VII peak fp32 @800MHz ....... 76.8 GFLOPS\n"
      "  SoC memory interface (shared w/ CPU) ... 17 GB/s\n"
      "  4x Cortex-A76 @2.4GHz NEON peak fp32 ... ~150 GFLOPS\n"
      "  CPU StereoSGBM on this vehicle ......... 141.6 ms/frame @ 640x480 D=96\n"
      "  (the Stereo row is block matching, not SGM: no path aggregation,\n"
      "   so it is an upper bound on a GPU SGM port, not a prediction)\n");

  eglDestroyContext(display, context);
  eglTerminate(display);
  return 0;
}
