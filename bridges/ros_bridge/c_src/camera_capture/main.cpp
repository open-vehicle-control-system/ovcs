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
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <linux/dma-buf.h>
#include <memory>
#include <mutex>
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

// Messages go to the BEAM's logger as LOG records: the Port does not
// capture stderr.
enum LogLevel : uint8_t { LOG_INFO = 0, LOG_WARNING = 1, LOG_ERROR = 2 };

void log_message(LogLevel level, const char* format, ...) __attribute__((format(printf, 2, 3)));

void log_message(LogLevel level, const char* format, ...) {
  char buf[512];
  va_list args;
  va_start(args, format);
  std::vsnprintf(buf, sizeof(buf), format, args);
  va_end(args);
  auto record = ovcs::framing::build_log_record(level, buf);
  ovcs::framing::write_record(record.data(), record.size());
}

struct Args {
  int camera_id = 0;
  int width = 1280;
  int height = 720;
  int fps = 30;
  // 0 = no rotation, 180 = sensor mounted upside down. 90/270 require
  // the sensor + ISP to support transposed output; libcamera may
  // reject them depending on the driver.
  int rotation = 0;
  // libcamera's software camera sync on the Pi 5: one camera of a pair
  // is the server, the others clients that align their frame starts to
  // it. Off by default.
  int32_t sync_mode = controls::rpi::SyncModeOff;
  // Auto-exposure mode from the sensor's tuning file; negative leaves
  // libcamera's default (normal).
  int32_t exposure_mode = -1;
  // Dioptres (1 / focus distance in metres); negative leaves the lens
  // where libcamera puts it.
  float lens_position = -1.0f;
  // Sensor mode as its output size and bit depth; 0 lets libcamera pick
  // one from the output size, which can be a centre crop of the sensor.
  unsigned int sensor_width = 0;
  unsigned int sensor_height = 0;
  unsigned int sensor_bit_depth = 10;
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
    else if (a == "--sync" && next()) {
      std::string mode = argv[i];
      if (mode == "server") out.sync_mode = controls::rpi::SyncModeServer;
      else if (mode == "client") out.sync_mode = controls::rpi::SyncModeClient;
      else { log_message(LOG_WARNING, "--sync must be server or client"); return false; }
    }
    else if (a == "--exposure-mode" && next()) {
      std::string mode = argv[i];
      if (mode == "normal") out.exposure_mode = controls::ExposureNormal;
      else if (mode == "short") out.exposure_mode = controls::ExposureShort;
      else if (mode == "long") out.exposure_mode = controls::ExposureLong;
      else { log_message(LOG_WARNING, "--exposure-mode must be normal, short or long"); return false; }
    }
    else if (a == "--lens-position" && next()) out.lens_position = std::strtof(argv[i], nullptr);
    else if (a == "--sensor-mode" && next()) {
      // WIDTHxHEIGHT or WIDTHxHEIGHT:BITDEPTH
      if (std::sscanf(argv[i], "%ux%u:%u", &out.sensor_width, &out.sensor_height,
                      &out.sensor_bit_depth) < 2) {
        log_message(LOG_WARNING, "--sensor-mode must be WIDTHxHEIGHT[:BITDEPTH]");
        return false;
      }
    }
    else { log_message(LOG_WARNING, "unknown arg %s", a.c_str()); return false; }
  }
  return true;
}

std::atomic<bool> g_stop{false};

// libcamera writes its own log to stderr. Point stderr at a pipe and
// forward each line as a LOG record, so its errors reach the logger.
void forward_stderr() {
  int fds[2];
  if (pipe(fds) != 0) return;
  dup2(fds[1], STDERR_FILENO);
  close(fds[1]);
  std::thread([read_fd = fds[0]] {
    std::string line;
    char c;
    while (::read(read_fd, &c, 1) == 1) {
      if (c != '\n') {
        line += c;
        continue;
      }
      LogLevel level = line.find(" ERROR ") != std::string::npos || line.find(" FATAL ") != std::string::npos
                           ? LOG_ERROR
                           : line.find(" WARN ") != std::string::npos ? LOG_WARNING : LOG_INFO;
      log_message(level, "libcamera: %s", line.c_str());
      line.clear();
    }
  }).detach();
}


// Controls received on stdin, applied to the next request re-queued.
std::mutex g_pending_mutex;
ControlList g_pending(controls::controls);

bool read_exact(void* buf, size_t len) {
  auto* p = static_cast<uint8_t*>(buf);
  while (len > 0) {
    ssize_t n = ::read(STDIN_FILENO, p, len);
    if (n <= 0) return false;
    p += n;
    len -= static_cast<size_t>(n);
  }
  return true;
}

// One `key=value` command into `out`; false when the key or value is
// not understood.
bool parse_control(const std::string& command, ControlList& out) {
  auto eq = command.find('=');
  if (eq == std::string::npos) return false;
  std::string key = command.substr(0, eq), value = command.substr(eq + 1);
  char* end = nullptr;
  float number = std::strtof(value.c_str(), &end);
  bool numeric = end != value.c_str() && *end == '\0';

  if (key == "exposure_mode") {
    if (value == "normal") out.set(controls::AeExposureMode, controls::ExposureNormal);
    else if (value == "short") out.set(controls::AeExposureMode, controls::ExposureShort);
    else if (value == "long") out.set(controls::AeExposureMode, controls::ExposureLong);
    else return false;
  } else if (key == "exposure_time_us" && numeric) {
    // 0 hands the exposure back to the auto-exposure.
    if (number <= 0) {
      out.set(controls::ExposureTimeMode, controls::ExposureTimeModeAuto);
    } else {
      out.set(controls::ExposureTimeMode, controls::ExposureTimeModeManual);
      out.set(controls::ExposureTime, static_cast<int32_t>(number));
    }
  } else if (key == "analogue_gain" && numeric) {
    if (number <= 0) {
      out.set(controls::AnalogueGainMode, controls::AnalogueGainModeAuto);
    } else {
      out.set(controls::AnalogueGainMode, controls::AnalogueGainModeManual);
      out.set(controls::AnalogueGain, number);
    }
  } else if (key == "lens_position" && numeric) {
    out.set(controls::AfMode, controls::AfModeManual);
    out.set(controls::LensPosition, number);
  } else if (key == "brightness" && numeric) {
    out.set(controls::Brightness, number);
  } else if (key == "contrast" && numeric) {
    out.set(controls::Contrast, number);
  } else if (key == "sharpness" && numeric) {
    out.set(controls::Sharpness, number);
  } else if (key == "noise_reduction") {
    if (value == "off") out.set(controls::draft::NoiseReductionMode, controls::draft::NoiseReductionModeOff);
    else if (value == "fast") out.set(controls::draft::NoiseReductionMode, controls::draft::NoiseReductionModeFast);
    else if (value == "high_quality") out.set(controls::draft::NoiseReductionMode, controls::draft::NoiseReductionModeHighQuality);
    else if (value == "minimal") out.set(controls::draft::NoiseReductionMode, controls::draft::NoiseReductionModeMinimal);
    else return false;
  } else {
    return false;
  }
  return true;
}

// stdin carries the Port's {:packet, 4} records: a 4-byte big-endian
// length, then one `key=value` command. EOF (the BEAM closing the
// Port) stops the capture.
void stdin_reader() {
  while (true) {
    uint8_t header[4];
    if (!read_exact(header, sizeof(header))) break;
    uint32_t len = (uint32_t(header[0]) << 24) | (uint32_t(header[1]) << 16) |
                   (uint32_t(header[2]) << 8) | uint32_t(header[3]);
    std::string command(len, '\0');
    if (len > 0 && !read_exact(command.data(), len)) break;

    ControlList parsed(controls::controls);
    if (parse_control(command, parsed)) {
      std::lock_guard<std::mutex> lock(g_pending_mutex);
      g_pending.merge(parsed, ControlList::MergePolicy::OverwriteExisting);
      log_message(LOG_INFO, "control %s", command.c_str());
    } else {
      log_message(LOG_WARNING, "control not understood: %s", command.c_str());
    }
  }
  g_stop.store(true);
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
        log_message(LOG_ERROR, "mmap(fd=%d, len=%zu) failed: %s",
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
  forward_stderr();

  Args args;
  if (!parse_args(argc, argv, args)) return 2;

  log_message(LOG_INFO, "camera=%d %dx%d @%d fps",
               args.camera_id, args.width, args.height, args.fps);

  std::thread reader(stdin_reader);
  reader.detach();

  // ---- libcamera bring-up --------------------------------------
  CameraManager cm;
  if (int ret = cm.start(); ret != 0) {
    log_message(LOG_ERROR, "CameraManager::start failed (%d)", ret);
    return 1;
  }

  const auto& cameras = cm.cameras();
  if (cameras.empty()) {
    log_message(LOG_ERROR, "no cameras detected by libcamera");
    cm.stop();
    return 1;
  }
  if (args.camera_id < 0 || static_cast<size_t>(args.camera_id) >= cameras.size()) {
    log_message(LOG_ERROR, "camera_id %d out of range (have %zu cameras)",
                 args.camera_id, cameras.size());
    cm.stop();
    return 1;
  }

  std::shared_ptr<Camera> camera = cameras[args.camera_id];
  if (camera->acquire() != 0) {
    log_message(LOG_ERROR, "Camera::acquire failed (camera %d)",
                 args.camera_id);
    cm.stop();
    return 1;
  }

  std::unique_ptr<CameraConfiguration> config =
      camera->generateConfiguration({StreamRole::VideoRecording});
  if (!config || config->size() != 1) {
    log_message(LOG_ERROR, "generateConfiguration failed");
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
      log_message(LOG_ERROR, "--rotation %d unsupported (use 0/90/180/270)",
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

  if (args.sensor_width > 0) {
    SensorConfiguration sensor;
    sensor.bitDepth = args.sensor_bit_depth;
    sensor.outputSize = Size(args.sensor_width, args.sensor_height);
    config->sensorConfig = sensor;
  }

  switch (config->validate()) {
    case CameraConfiguration::Valid:
      break;
    case CameraConfiguration::Adjusted:
      log_message(LOG_INFO, "configuration adjusted to %ux%u %s",
                   cfg.size.width, cfg.size.height,
                   cfg.pixelFormat.toString().c_str());
      break;
    case CameraConfiguration::Invalid:
      log_message(LOG_ERROR, args.sensor_width > 0
                                 ? "configuration invalid: no %ux%u %u-bit sensor mode?"
                                 : "configuration invalid",
                  args.sensor_width, args.sensor_height, args.sensor_bit_depth);
      camera->release();
      cm.stop();
      return 1;
  }

  if (cfg.pixelFormat != formats::YUV420) {
    log_message(LOG_ERROR, "driver refused YUV420 (got %s); aborting",
                 cfg.pixelFormat.toString().c_str());
    camera->release();
    cm.stop();
    return 1;
  }

  if (camera->configure(config.get()) != 0) {
    log_message(LOG_ERROR, "Camera::configure failed");
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
    log_message(LOG_ERROR, "buffer allocation failed");
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
      log_message(LOG_ERROR, "buffer has no planes");
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
      log_message(LOG_ERROR, "failed to mmap buffer planes");
      camera->release();
      cm.stop();
      return 1;
    }
    views.emplace(buffer.get(), view);

    auto request = camera->createRequest();
    if (!request) {
      log_message(LOG_ERROR, "createRequest failed");
      camera->release();
      cm.stop();
      return 1;
    }
    if (request->addBuffer(stream, buffer.get()) != 0) {
      log_message(LOG_ERROR, "addBuffer failed");
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
    log_message(LOG_ERROR, "tjInitCompress failed");
    camera->release();
    cm.stop();
    return 1;
  }
  const unsigned long max_jpeg_size =
      tjBufSize(static_cast<int>(out_width), static_cast<int>(out_height),
                TJSAMP_420);
  unsigned char* jpeg_buf = tjAlloc(static_cast<int>(max_jpeg_size));
  if (!jpeg_buf) {
    log_message(LOG_ERROR, "tjAlloc(%lu) failed", max_jpeg_size);
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

  bool sync_reported = false;
  int frames_without_sync = 0;
  constexpr int kSyncPatienceFrames = 300;
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
    if (args.sync_mode != controls::rpi::SyncModeOff && !sync_reported) {
      ++frames_without_sync;
      if (auto ready = request->metadata().get(controls::rpi::SyncReady); ready && *ready) {
        log_message(LOG_INFO, "camera sync established after %d frames", frames_without_sync);
        sync_reported = true;
      } else if (frames_without_sync == kSyncPatienceFrames) {
        log_message(LOG_WARNING, "camera sync not established after %d frames", kSyncPatienceFrames);
      }
    }

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
      log_message(LOG_WARNING, "tjCompressFromYUVPlanes: %s",
                   tjGetErrorStr2(jpeg));
    }

    request->reuse(Request::ReuseBuffers);
    {
      std::lock_guard<std::mutex> lock(g_pending_mutex);
      if (!g_pending.empty()) {
        request->controls().merge(g_pending, ControlList::MergePolicy::OverwriteExisting);
        g_pending.clear();
      }
    }
    camera->queueRequest(request);
  });

  // ---- start + initial queue -----------------------------------
  ControlList start_controls(controls::controls);
  const int64_t period_us = 1'000'000 / std::max(args.fps, 1);
  start_controls.set(controls::FrameDurationLimits,
                     Span<const int64_t, 2>({period_us, period_us}));

  // The widest crop the sensor mode allows. A mode can itself be a
  // centre crop of the sensor (see --sensor-mode).
  if (auto max_crop = camera->properties().get(properties::ScalerCropMaximum)) {
    start_controls.set(controls::ScalerCrop, *max_crop);
    log_message(LOG_INFO, "ScalerCrop set to the sensor mode's full area (%dx%d @ %d,%d)",
                 max_crop->width, max_crop->height,
                 max_crop->x, max_crop->y);
  } else {
    log_message(LOG_WARNING, "ScalerCropMaximum unavailable; FoV may be cropped");
  }

  if (args.sync_mode != controls::rpi::SyncModeOff) {
    if (camera->controls().count(&controls::rpi::SyncMode)) {
      start_controls.set(controls::rpi::SyncMode, args.sync_mode);
      log_message(LOG_INFO, "camera sync as %s",
                   args.sync_mode == controls::rpi::SyncModeServer ? "server" : "client");
    } else {
      log_message(LOG_WARNING, "no camera sync on this pipeline; --sync ignored");
    }
  }

  if (args.exposure_mode >= 0) {
    start_controls.set(controls::AeExposureMode, args.exposure_mode);
    log_message(LOG_INFO, "auto-exposure mode %d", args.exposure_mode);
  }

  // A stereo calibration holds only while the lens stays put: focus is
  // manual and fixed when a position is given.
  if (args.lens_position >= 0.0f) {
    if (camera->controls().count(&controls::AfMode) && camera->controls().count(&controls::LensPosition)) {
      start_controls.set(controls::AfMode, controls::AfModeManual);
      start_controls.set(controls::LensPosition, args.lens_position);
      log_message(LOG_INFO, "focus fixed at %.2f dioptres", args.lens_position);
    } else {
      log_message(LOG_WARNING, "no focus control on this sensor; --lens-position ignored");
    }
  }

  if (camera->start(&start_controls) != 0) {
    log_message(LOG_ERROR, "Camera::start failed");
    tjDestroy(jpeg);
    camera->release();
    cm.stop();
    return 1;
  }

  for (auto& request : requests) {
    if (camera->queueRequest(request.get()) != 0) {
      log_message(LOG_ERROR, "initial queueRequest failed");
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
