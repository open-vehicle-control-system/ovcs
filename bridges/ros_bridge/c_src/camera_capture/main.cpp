// camera_capture — opens a single libcamera CSI sensor and writes
// JPEG frames to stdout in the OVCS port framing protocol (see
// ../common/framing.h).
//
// Pipeline:
//   1. CameraManager::start()
//   2. Acquire cameras()[args.camera_id]
//   3. generateConfiguration({StreamRole::VideoRecording}) at
//      args.width × args.height, pixel format YUV420
//   4. FrameBufferAllocator + mmap each buffer's planes once
//   5. Create one Request per buffer, queueRequest
//   6. requestCompleted slot: encode YUV420 → JPEG via libjpeg-turbo,
//      write_record(...), reuse(Request::ReuseBuffers), re-queue
//   7. Stop on stdin EOF (BEAM closing the Port)
//
// fps is enforced via FrameDurationLimits = [period_us, period_us].

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <linux/dma-buf.h>
#include <memory>
#include <string>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <vector>

#include <libcamera/libcamera.h>
#include <turbojpeg.h>

#include "framing.h"

using namespace libcamera;

namespace {

struct Args {
  int camera_id = 0;
  int width = 1280;
  int height = 720;
  int fps = 30;
  // 0 = no rotation, 180 = sensor mounted upside down. 90/270 require
  // the sensor + ISP to support transposed output; libcamera may
  // reject them depending on the driver.
  int rotation = 0;
};

bool parse_args(int argc, char** argv, Args& out) {
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : nullptr; };
    if (a == "--camera" && next()) out.camera_id = std::atoi(argv[i]);
    else if (a == "--width" && next()) out.width = std::atoi(argv[i]);
    else if (a == "--height" && next()) out.height = std::atoi(argv[i]);
    else if (a == "--fps" && next()) out.fps = std::atoi(argv[i]);
    else if (a == "--rotation" && next()) out.rotation = std::atoi(argv[i]);
    else { std::fprintf(stderr, "camera_capture: unknown arg %s\n", a.c_str()); return false; }
  }
  return true;
}

std::atomic<bool> g_stop{false};

void stdin_watcher() {
  char buf[16];
  while (true) {
    ssize_t n = ::read(STDIN_FILENO, buf, sizeof(buf));
    if (n <= 0) {
      g_stop.store(true);
      return;
    }
  }
}

int64_t monotonic_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// One mmap per unique buffer fd. libcamera frequently exposes a
// single dmabuf with several planes carved out at different offsets;
// mmap'ing each plane separately would map the same memory multiple
// times. Keying on fd lets us share one mapping across planes.
struct MappedFd {
  void* base = MAP_FAILED;
  size_t length = 0;
};

class FdMapper {
 public:
  ~FdMapper() {
    for (auto& [fd, m] : maps_) {
      if (m.base != MAP_FAILED) ::munmap(m.base, m.length);
    }
  }

  uint8_t* map_plane(int fd, size_t offset, size_t length) {
    auto it = maps_.find(fd);
    if (it == maps_.end()) {
      // Map the whole buffer (length is per-plane; the actual dmabuf
      // is usually larger). Use lseek to find the true size.
      off_t end = ::lseek(fd, 0, SEEK_END);
      size_t total = (end > 0) ? static_cast<size_t>(end) : (offset + length);
      void* p = ::mmap(nullptr, total, PROT_READ, MAP_SHARED, fd, 0);
      if (p == MAP_FAILED) {
        std::fprintf(stderr, "camera_capture: mmap(fd=%d, len=%zu) failed: %s\n",
                     fd, total, std::strerror(errno));
        return nullptr;
      }
      it = maps_.emplace(fd, MappedFd{p, total}).first;
    }
    return static_cast<uint8_t*>(it->second.base) + offset;
  }

 private:
  std::unordered_map<int, MappedFd> maps_;
};

// Pre-resolved per-buffer plane pointers + strides so the hot path
// only does encode + write, no map lookups. The fd list is what we
// hand to DMA_BUF_IOCTL_SYNC so the CPU sees coherent data when it
// reads the planes — on ARM (Pi 5) the dmabuf isn't cache-coherent
// by default and skipping the sync gives torn / stale pixels.
struct YuvView {
  const uint8_t* y;
  const uint8_t* u;
  const uint8_t* v;
  int y_stride;
  int uv_stride;
  std::vector<int> sync_fds;
};

inline void dmabuf_sync(const std::vector<int>& fds, uint64_t flags) {
  for (int fd : fds) {
    dma_buf_sync sync = {};
    sync.flags = flags;
    // EINTR is the only retryable error we'd care about here, and
    // even that's rare; ignoring failures keeps the hot path
    // branch-free without a meaningful safety cost (worst case the
    // CPU reads a stale line).
    ::ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
  }
}

}  // namespace

int main(int argc, char** argv) {
  Args args;
  if (!parse_args(argc, argv, args)) return 2;

  std::fprintf(stderr,
               "camera_capture: camera=%d %dx%d @%d fps\n",
               args.camera_id, args.width, args.height, args.fps);

  std::thread watcher(stdin_watcher);
  watcher.detach();

  // ---- libcamera bring-up --------------------------------------
  CameraManager cm;
  if (int ret = cm.start(); ret != 0) {
    std::fprintf(stderr, "camera_capture: CameraManager::start failed (%d)\n", ret);
    return 1;
  }

  const auto& cameras = cm.cameras();
  if (cameras.empty()) {
    std::fprintf(stderr, "camera_capture: no cameras detected by libcamera\n");
    cm.stop();
    return 1;
  }
  if (args.camera_id < 0 || static_cast<size_t>(args.camera_id) >= cameras.size()) {
    std::fprintf(stderr,
                 "camera_capture: camera_id %d out of range (have %zu cameras)\n",
                 args.camera_id, cameras.size());
    cm.stop();
    return 1;
  }

  std::shared_ptr<Camera> camera = cameras[args.camera_id];
  if (camera->acquire() != 0) {
    std::fprintf(stderr, "camera_capture: Camera::acquire failed (camera %d)\n",
                 args.camera_id);
    cm.stop();
    return 1;
  }

  std::unique_ptr<CameraConfiguration> config =
      camera->generateConfiguration({StreamRole::VideoRecording});
  if (!config || config->size() != 1) {
    std::fprintf(stderr, "camera_capture: generateConfiguration failed\n");
    camera->release();
    cm.stop();
    return 1;
  }

  // Rotate the frame in-pipeline. Without this an upside-down
  // sensor produces an upside-down JPEG.
  switch (args.rotation) {
    case 0:   config->orientation = Orientation::Rotate0;   break;
    case 90:  config->orientation = Orientation::Rotate90;  break;
    case 180: config->orientation = Orientation::Rotate180; break;
    case 270: config->orientation = Orientation::Rotate270; break;
    default:
      std::fprintf(stderr,
                   "camera_capture: --rotation %d unsupported (use 0/90/180/270)\n",
                   args.rotation);
      camera->release();
      cm.stop();
      return 2;
  }

  StreamConfiguration& cfg = config->at(0);
  cfg.size = Size(static_cast<unsigned int>(args.width),
                  static_cast<unsigned int>(args.height));
  cfg.pixelFormat = formats::YUV420;
  cfg.bufferCount = 4;

  switch (config->validate()) {
    case CameraConfiguration::Valid:
      break;
    case CameraConfiguration::Adjusted:
      std::fprintf(stderr,
                   "camera_capture: configuration adjusted to %ux%u %s\n",
                   cfg.size.width, cfg.size.height,
                   cfg.pixelFormat.toString().c_str());
      break;
    case CameraConfiguration::Invalid:
      std::fprintf(stderr, "camera_capture: configuration invalid\n");
      camera->release();
      cm.stop();
      return 1;
  }

  if (cfg.pixelFormat != formats::YUV420) {
    std::fprintf(stderr,
                 "camera_capture: driver refused YUV420 (got %s); aborting\n",
                 cfg.pixelFormat.toString().c_str());
    camera->release();
    cm.stop();
    return 1;
  }

  if (camera->configure(config.get()) != 0) {
    std::fprintf(stderr, "camera_capture: Camera::configure failed\n");
    camera->release();
    cm.stop();
    return 1;
  }

  Stream* stream = cfg.stream();
  const unsigned int out_width = cfg.size.width;
  const unsigned int out_height = cfg.size.height;
  const unsigned int y_stride = cfg.stride;
  // libcamera's YUV420 packs U and V at half the line stride. This
  // matches the I420 layout turbojpeg expects.
  const unsigned int uv_stride = y_stride / 2;

  // ---- buffer allocation + mmap --------------------------------
  FrameBufferAllocator allocator(camera);
  if (allocator.allocate(stream) < 0) {
    std::fprintf(stderr, "camera_capture: buffer allocation failed\n");
    camera->release();
    cm.stop();
    return 1;
  }

  FdMapper mapper;
  std::unordered_map<FrameBuffer*, YuvView> views;
  std::vector<std::unique_ptr<Request>> requests;

  for (const auto& buffer : allocator.buffers(stream)) {
    const auto& planes = buffer->planes();
    if (planes.empty()) {
      std::fprintf(stderr, "camera_capture: buffer has no planes\n");
      camera->release();
      cm.stop();
      return 1;
    }

    YuvView view{};
    view.y_stride = static_cast<int>(y_stride);
    view.uv_stride = static_cast<int>(uv_stride);

    auto track_fd = [&](int fd) {
      if (std::find(view.sync_fds.begin(), view.sync_fds.end(), fd) == view.sync_fds.end()) {
        view.sync_fds.push_back(fd);
      }
    };

    if (planes.size() >= 3) {
      view.y = mapper.map_plane(planes[0].fd.get(), planes[0].offset, planes[0].length);
      view.u = mapper.map_plane(planes[1].fd.get(), planes[1].offset, planes[1].length);
      view.v = mapper.map_plane(planes[2].fd.get(), planes[2].offset, planes[2].length);
      track_fd(planes[0].fd.get());
      track_fd(planes[1].fd.get());
      track_fd(planes[2].fd.get());
    } else {
      // Single-plane dmabuf: Y/U/V live at known offsets within it.
      const size_t y_size = static_cast<size_t>(y_stride) * out_height;
      const size_t uv_size = static_cast<size_t>(uv_stride) * (out_height / 2);
      uint8_t* base = mapper.map_plane(planes[0].fd.get(), planes[0].offset,
                                       y_size + 2 * uv_size);
      if (!base) { camera->release(); cm.stop(); return 1; }
      view.y = base;
      view.u = base + y_size;
      view.v = base + y_size + uv_size;
      track_fd(planes[0].fd.get());
    }

    if (!view.y || !view.u || !view.v) {
      std::fprintf(stderr, "camera_capture: failed to mmap buffer planes\n");
      camera->release();
      cm.stop();
      return 1;
    }
    views.emplace(buffer.get(), view);

    auto request = camera->createRequest();
    if (!request) {
      std::fprintf(stderr, "camera_capture: createRequest failed\n");
      camera->release();
      cm.stop();
      return 1;
    }
    if (request->addBuffer(stream, buffer.get()) != 0) {
      std::fprintf(stderr, "camera_capture: addBuffer failed\n");
      camera->release();
      cm.stop();
      return 1;
    }
    requests.push_back(std::move(request));
  }

  // ---- JPEG encoder + pre-allocated output buffer --------------
  //
  // libcamera serialises `requestCompleted` slot invocations on the
  // camera's internal thread, so the slot is effectively
  // single-threaded for a given camera and we don't need a mutex
  // around writes or the encoder handle. We also pre-allocate the
  // JPEG output buffer once at its theoretical max size and pass
  // `TJFLAG_NOREALLOC` so the hot path never mallocs.
  tjhandle jpeg = tjInitCompress();
  if (!jpeg) {
    std::fprintf(stderr, "camera_capture: tjInitCompress failed\n");
    camera->release();
    cm.stop();
    return 1;
  }
  const unsigned long max_jpeg_size =
      tjBufSize(static_cast<int>(out_width), static_cast<int>(out_height),
                TJSAMP_420);
  unsigned char* jpeg_buf = tjAlloc(static_cast<int>(max_jpeg_size));
  if (!jpeg_buf) {
    std::fprintf(stderr, "camera_capture: tjAlloc(%lu) failed\n", max_jpeg_size);
    tjDestroy(jpeg);
    camera->release();
    cm.stop();
    return 1;
  }

  // Reusable record buffer keyed by per-callback locality. The header
  // is fixed size; only the JPEG body changes per frame. Reserve once
  // to dodge realloc in the hot path.
  std::vector<uint8_t> record;
  record.reserve(1 + 2 + 2 + 8 + 4 + max_jpeg_size);

  camera->requestCompleted.connect(camera.get(), [&](Request* request) {
    if (request->status() == Request::RequestCancelled) return;
    if (g_stop.load()) return;

    auto buf_it = request->buffers().find(stream);
    if (buf_it == request->buffers().end()) return;
    FrameBuffer* buffer = buf_it->second;

    auto vit = views.find(buffer);
    if (vit == views.end()) return;
    const YuvView& view = vit->second;

    // Prefer the sensor-side capture timestamp: it's the actual
    // exposure-midpoint time, so stereo pairing (which compares
    // |t_left - t_right|) sees the genuine sync offset instead of
    // post-DMA scheduling jitter. Falls back to monotonic_ns() if
    // libcamera/the driver doesn't report it.
    int64_t capture_ns = 0;
    if (auto ts = request->metadata().get(controls::SensorTimestamp)) {
      capture_ns = static_cast<int64_t>(*ts);
    } else {
      capture_ns = monotonic_ns();
    }

    // CPU-side cache invalidate before reading the dmabuf — required
    // by the dma-buf API to see writes the ISP just made.
    dmabuf_sync(view.sync_fds, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);

    unsigned long jpeg_size = max_jpeg_size;
    const unsigned char* planes[3] = {view.y, view.u, view.v};
    int strides[3] = {view.y_stride, view.uv_stride, view.uv_stride};
    int rc = tjCompressFromYUVPlanes(jpeg, planes, static_cast<int>(out_width),
                                     strides, static_cast<int>(out_height),
                                     TJSAMP_420, &jpeg_buf, &jpeg_size, 85,
                                     TJFLAG_FASTDCT | TJFLAG_NOREALLOC);

    dmabuf_sync(view.sync_fds, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);

    if (rc == 0) {
      record = ovcs::framing::build_frame_record(
          static_cast<uint16_t>(out_width),
          static_cast<uint16_t>(out_height),
          capture_ns,
          jpeg_buf, static_cast<size_t>(jpeg_size));
      if (!ovcs::framing::write_record(record.data(), record.size())) {
        g_stop.store(true);
      }
    } else {
      std::fprintf(stderr, "camera_capture: tjCompressFromYUVPlanes: %s\n",
                   tjGetErrorStr2(jpeg));
    }

    request->reuse(Request::ReuseBuffers);
    camera->queueRequest(request);
  });

  // ---- start + initial queue -----------------------------------
  ControlList start_controls(controls::controls);
  const int64_t period_us = 1'000'000 / std::max(args.fps, 1);
  start_controls.set(controls::FrameDurationLimits,
                     Span<const int64_t, 2>({period_us, period_us}));

  // Without an explicit ScalerCrop libcamera/PISP may pick a sensor
  // mode whose native dimensions exceed the requested output and
  // present it as a centre crop — looks "zoomed in" with a narrower
  // FoV than the lens delivers. Pin the crop to the full active
  // sensor area so the downscale to args.{width,height} preserves the
  // lens's full FoV.
  if (auto max_crop = camera->properties().get(properties::ScalerCropMaximum)) {
    start_controls.set(controls::ScalerCrop, *max_crop);
    std::fprintf(stderr,
                 "camera_capture: ScalerCrop set to full sensor (%dx%d @ %d,%d)\n",
                 max_crop->width, max_crop->height,
                 max_crop->x, max_crop->y);
  } else {
    std::fprintf(stderr,
                 "camera_capture: ScalerCropMaximum unavailable; FoV may be cropped\n");
  }

  if (camera->start(&start_controls) != 0) {
    std::fprintf(stderr, "camera_capture: Camera::start failed\n");
    tjDestroy(jpeg);
    camera->release();
    cm.stop();
    return 1;
  }

  for (auto& request : requests) {
    if (camera->queueRequest(request.get()) != 0) {
      std::fprintf(stderr, "camera_capture: initial queueRequest failed\n");
      g_stop.store(true);
      break;
    }
  }

  // ---- main thread idles until stop ----------------------------
  while (!g_stop.load()) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }

  camera->stop();
  allocator.free(stream);
  camera->release();
  cm.stop();
  if (jpeg_buf) tjFree(jpeg_buf);
  tjDestroy(jpeg);
  return 0;
}
