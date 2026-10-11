// camera_capture: one libcamera sensor, YUV420 encoded to JPEG FRAME records on
// stdout (../common/framing.h); `Name=value` controls arrive on stdin, and
// stdin EOF stops the capture.

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
  char message[512];
  va_list args;
  va_start(args, format);
  std::vsnprintf(message, sizeof(message), format, args);
  va_end(args);
  auto record = ovcs::framing::build_log_record(level, message);
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
    std::string flag = argv[i];
    auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : nullptr; };
    if (flag == "--camera" && next()) out.camera_id = std::atoi(argv[i]);
    else if (flag == "--width" && next()) out.width = std::atoi(argv[i]);
    else if (flag == "--height" && next()) out.height = std::atoi(argv[i]);
    else if (flag == "--fps" && next()) out.fps = std::atoi(argv[i]);
    else if (flag == "--rotation" && next()) out.rotation = std::atoi(argv[i]);
    else if (flag == "--sync" && next()) {
      std::string mode = argv[i];
      if (mode == "server") out.sync_mode = controls::rpi::SyncModeServer;
      else if (mode == "client") out.sync_mode = controls::rpi::SyncModeClient;
      else { log_message(LOG_WARNING, "--sync must be server or client"); return false; }
    }
    else if (flag == "--exposure-mode" && next()) {
      std::string mode = argv[i];
      if (mode == "normal") out.exposure_mode = controls::ExposureNormal;
      else if (mode == "short") out.exposure_mode = controls::ExposureShort;
      else if (mode == "long") out.exposure_mode = controls::ExposureLong;
      else { log_message(LOG_WARNING, "--exposure-mode must be normal, short or long"); return false; }
    }
    else if (flag == "--lens-position" && next()) out.lens_position = std::strtof(argv[i], nullptr);
    else if (flag == "--sensor-mode" && next()) {
      // WIDTHxHEIGHT or WIDTHxHEIGHT:BITDEPTH
      if (std::sscanf(argv[i], "%ux%u:%u", &out.sensor_width, &out.sensor_height,
                      &out.sensor_bit_depth) < 2) {
        log_message(LOG_WARNING, "--sensor-mode must be WIDTHxHEIGHT[:BITDEPTH]");
        return false;
      }
    }
    else { log_message(LOG_WARNING, "unknown arg %s", flag.c_str()); return false; }
  }
  return true;
}

std::atomic<bool> g_stop{false};

// Value order of the METADATA record.
enum MetadataField : size_t {
  kExposureTimeUs,
  kAnalogueGain,
  kDigitalGain,
  kLensPositionDioptres,
  kFrameDurationUs,
  kColourTemperatureK,
  kSyncReady,
  kSyncTimerUs,
};

// What libcamera applied to a frame.
void send_metadata(const ControlList& metadata, int64_t capture_ns) {
  double values[ovcs::framing::kMetadataFields] = {};
  uint8_t present = 0;
  auto put = [&](size_t i, auto value) {
    if (value) {
      values[i] = static_cast<double>(*value);
      present |= uint8_t(1u << i);
    }
  };
  put(kExposureTimeUs, metadata.get(controls::ExposureTime));
  put(kAnalogueGain, metadata.get(controls::AnalogueGain));
  put(kDigitalGain, metadata.get(controls::DigitalGain));
  put(kLensPositionDioptres, metadata.get(controls::LensPosition));
  put(kFrameDurationUs, metadata.get(controls::FrameDuration));
  put(kColourTemperatureK, metadata.get(controls::ColourTemperature));
  put(kSyncReady, metadata.get(controls::rpi::SyncReady));
  put(kSyncTimerUs, metadata.get(controls::rpi::SyncTimer));
  auto record = ovcs::framing::build_metadata_record(capture_ns, present, values);
  ovcs::framing::write_record(record.data(), record.size());
}

// libcamera writes its own log to stderr. Point stderr at a pipe and
// forward each line as a LOG record, so its errors reach the logger.
void forward_stderr() {
  int fds[2];
  if (pipe(fds) != 0) return;
  dup2(fds[1], STDERR_FILENO);
  close(fds[1]);
  std::thread([read_fd = fds[0]] {
    std::string line;
    char character;
    while (::read(read_fd, &character, 1) == 1) {
      if (character != '\n') {
        line += character;
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
ControlList g_pending_controls(controls::controls);

bool read_exact(void* buffer, size_t length) {
  auto* cursor = static_cast<uint8_t*>(buffer);
  while (length > 0) {
    ssize_t transferred = ::read(STDIN_FILENO, cursor, length);
    if (transferred <= 0) return false;
    cursor += transferred;
    length -= static_cast<size_t>(transferred);
  }
  return true;
}

// One `Name=value` command into `out`: a libcamera control by its name,
// the value parsed for the control's type. False when either is not
// understood.
bool parse_control(const std::string& command, ControlList& out) {
  auto separator = command.find('=');
  if (separator == std::string::npos) return false;
  const std::string name = command.substr(0, separator), value = command.substr(separator + 1);

  const ControlId* id = nullptr;
  for (const auto& [_, candidate] : controls::controls) {
    if (candidate->name() == name && !candidate->isArray()) {
      id = candidate;
      break;
    }
  }
  if (!id || value.empty()) return false;

  char* end = nullptr;
  switch (id->type()) {
    case ControlTypeBool:
      if (value != "0" && value != "1") return false;
      out.set(id->id(), ControlValue(value == "1"));
      return true;
    case ControlTypeInteger32: {
      long parsed = std::strtol(value.c_str(), &end, 10);
      if (*end != '\0') return false;
      out.set(id->id(), ControlValue(static_cast<int32_t>(parsed)));
      return true;
    }
    case ControlTypeInteger64: {
      long long parsed = std::strtoll(value.c_str(), &end, 10);
      if (*end != '\0') return false;
      out.set(id->id(), ControlValue(static_cast<int64_t>(parsed)));
      return true;
    }
    case ControlTypeFloat: {
      float parsed = std::strtof(value.c_str(), &end);
      if (*end != '\0') return false;
      out.set(id->id(), ControlValue(parsed));
      return true;
    }
    default:
      return false;
  }
}

// stdin carries the Port's {:packet, 4} records: a 4-byte big-endian
// length, then one `Name=value` command. EOF (the BEAM closing the
// Port) stops the capture.
void stdin_reader() {
  while (true) {
    uint8_t header[4];
    if (!read_exact(header, sizeof(header))) break;
    uint32_t length = (uint32_t(header[0]) << 24) | (uint32_t(header[1]) << 16) |
                      (uint32_t(header[2]) << 8) | uint32_t(header[3]);
    std::string command(length, '\0');
    if (length > 0 && !read_exact(command.data(), length)) break;

    ControlList parsed(controls::controls);
    if (parse_control(command, parsed)) {
      std::lock_guard<std::mutex> lock(g_pending_mutex);
      g_pending_controls.merge(parsed, ControlList::MergePolicy::OverwriteExisting);
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

// One mmap per dmabuf fd: libcamera often carves several planes out of one buffer.
struct MappedFd {
  void* base = MAP_FAILED;
  size_t length = 0;
};

class FdMapper {
 public:
  ~FdMapper() {
    for (auto& [fd, mapping] : maps_) {
      if (mapping.base != MAP_FAILED) ::munmap(mapping.base, mapping.length);
    }
  }

  uint8_t* map_plane(int fd, size_t offset, size_t length) {
    auto it = maps_.find(fd);
    if (it == maps_.end()) {
      // Map the whole buffer (length is per-plane; the actual dmabuf
      // is usually larger). Use lseek to find the true size.
      off_t end = ::lseek(fd, 0, SEEK_END);
      size_t total = (end > 0) ? static_cast<size_t>(end) : (offset + length);
      void* base = ::mmap(nullptr, total, PROT_READ, MAP_SHARED, fd, 0);
      if (base == MAP_FAILED) {
        log_message(LOG_ERROR, "mmap(fd=%d, len=%zu) failed: %s",
                     fd, total, std::strerror(errno));
        return nullptr;
      }
      it = maps_.emplace(fd, MappedFd{base, total}).first;
    }
    return static_cast<uint8_t*>(it->second.base) + offset;
  }

 private:
  std::unordered_map<int, MappedFd> maps_;
};

// Plane pointers resolved once per buffer. The dmabuf is not cache-coherent on
// the Pi 5: sync_fds go to DMA_BUF_IOCTL_SYNC around every CPU read.
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
    // Failure ignored: the worst case is one stale cache line.
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

  CameraManager camera_manager;
  if (int status = camera_manager.start(); status != 0) {
    log_message(LOG_ERROR, "CameraManager::start failed (%d)", status);
    return 1;
  }

  const auto& cameras = camera_manager.cameras();
  if (cameras.empty()) {
    log_message(LOG_ERROR, "no cameras detected by libcamera");
    camera_manager.stop();
    return 1;
  }
  if (args.camera_id < 0 || static_cast<size_t>(args.camera_id) >= cameras.size()) {
    log_message(LOG_ERROR, "camera_id %d out of range (have %zu cameras)",
                 args.camera_id, cameras.size());
    camera_manager.stop();
    return 1;
  }

  std::shared_ptr<Camera> camera = cameras[args.camera_id];
  if (camera->acquire() != 0) {
    log_message(LOG_ERROR, "Camera::acquire failed (camera %d)",
                 args.camera_id);
    camera_manager.stop();
    return 1;
  }

  std::unique_ptr<CameraConfiguration> config =
      camera->generateConfiguration({StreamRole::VideoRecording});
  if (!config || config->size() != 1) {
    log_message(LOG_ERROR, "generateConfiguration failed");
    camera->release();
    camera_manager.stop();
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
      camera_manager.stop();
      return 2;
  }

  StreamConfiguration& stream_config = config->at(0);
  stream_config.size = Size(static_cast<unsigned int>(args.width),
                  static_cast<unsigned int>(args.height));
  stream_config.pixelFormat = formats::YUV420;
  stream_config.bufferCount = 4;

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
                   stream_config.size.width, stream_config.size.height,
                   stream_config.pixelFormat.toString().c_str());
      break;
    case CameraConfiguration::Invalid:
      log_message(LOG_ERROR, args.sensor_width > 0
                                 ? "configuration invalid: no %ux%u %u-bit sensor mode?"
                                 : "configuration invalid",
                  args.sensor_width, args.sensor_height, args.sensor_bit_depth);
      camera->release();
      camera_manager.stop();
      return 1;
  }

  if (stream_config.pixelFormat != formats::YUV420) {
    log_message(LOG_ERROR, "driver refused YUV420 (got %s); aborting",
                 stream_config.pixelFormat.toString().c_str());
    camera->release();
    camera_manager.stop();
    return 1;
  }

  if (camera->configure(config.get()) != 0) {
    log_message(LOG_ERROR, "Camera::configure failed");
    camera->release();
    camera_manager.stop();
    return 1;
  }

  Stream* stream = stream_config.stream();
  const unsigned int out_width = stream_config.size.width;
  const unsigned int out_height = stream_config.size.height;
  const unsigned int y_stride = stream_config.stride;
  // libcamera's YUV420 packs U and V at half the line stride. This
  // matches the I420 layout turbojpeg expects.
  const unsigned int uv_stride = y_stride / 2;

  FrameBufferAllocator allocator(camera);
  if (allocator.allocate(stream) < 0) {
    log_message(LOG_ERROR, "buffer allocation failed");
    camera->release();
    camera_manager.stop();
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
      camera_manager.stop();
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
      if (!base) { camera->release(); camera_manager.stop(); return 1; }
      view.y = base;
      view.u = base + y_size;
      view.v = base + y_size + uv_size;
      track_fd(planes[0].fd.get());
    }

    if (!view.y || !view.u || !view.v) {
      log_message(LOG_ERROR, "failed to mmap buffer planes");
      camera->release();
      camera_manager.stop();
      return 1;
    }
    views.emplace(buffer.get(), view);

    auto request = camera->createRequest();
    if (!request) {
      log_message(LOG_ERROR, "createRequest failed");
      camera->release();
      camera_manager.stop();
      return 1;
    }
    if (request->addBuffer(stream, buffer.get()) != 0) {
      log_message(LOG_ERROR, "addBuffer failed");
      camera->release();
      camera_manager.stop();
      return 1;
    }
    requests.push_back(std::move(request));
  }

  // requestCompleted runs on libcamera's single camera thread: no locking around
  // the encoder. TJFLAG_NOREALLOC into a max-size buffer keeps malloc off the hot path.
  tjhandle jpeg_encoder = tjInitCompress();
  if (!jpeg_encoder) {
    log_message(LOG_ERROR, "tjInitCompress failed");
    camera->release();
    camera_manager.stop();
    return 1;
  }
  const unsigned long max_jpeg_size =
      tjBufSize(static_cast<int>(out_width), static_cast<int>(out_height),
                TJSAMP_420);
  unsigned char* jpeg_buffer = tjAlloc(static_cast<int>(max_jpeg_size));
  if (!jpeg_buffer) {
    log_message(LOG_ERROR, "tjAlloc(%lu) failed", max_jpeg_size);
    tjDestroy(jpeg_encoder);
    camera->release();
    camera_manager.stop();
    return 1;
  }

  std::vector<uint8_t> record;
  record.reserve(1 + 2 + 2 + 8 + 4 + max_jpeg_size);

  bool sync_reported = false;
  int frames_without_sync = 0;
  constexpr int kSyncPatienceFrames = 300;
  int frames_since_metadata = 0;
  constexpr int kMetadataEveryFrames = 5;
  constexpr int kJpegQuality = 85;
  camera->requestCompleted.connect(camera.get(), [&](Request* request) {
    if (request->status() == Request::RequestCancelled) return;
    if (g_stop.load()) return;

    auto buffer_entry = request->buffers().find(stream);
    if (buffer_entry == request->buffers().end()) return;
    FrameBuffer* buffer = buffer_entry->second;

    auto view_entry = views.find(buffer);
    if (view_entry == views.end()) return;
    const YuvView& view = view_entry->second;

    if (args.sync_mode != controls::rpi::SyncModeOff && !sync_reported) {
      ++frames_without_sync;
      if (auto ready = request->metadata().get(controls::rpi::SyncReady); ready && *ready) {
        log_message(LOG_INFO, "camera sync established after %d frames", frames_without_sync);
        sync_reported = true;
      } else if (frames_without_sync == kSyncPatienceFrames) {
        log_message(LOG_WARNING, "camera sync not established after %d frames", kSyncPatienceFrames);
      }
    }

    // Sensor timestamp, so stereo pairing sees the true sync offset rather
    // than DMA scheduling jitter; monotonic when the driver has none.
    int64_t capture_ns = 0;
    if (auto sensor_timestamp = request->metadata().get(controls::SensorTimestamp)) {
      capture_ns = static_cast<int64_t>(*sensor_timestamp);
    } else {
      capture_ns = monotonic_ns();
    }

    if (++frames_since_metadata >= kMetadataEveryFrames) {
      frames_since_metadata = 0;
      send_metadata(request->metadata(), capture_ns);
    }

    // CPU-side cache invalidate before reading the dmabuf — required
    // by the dma-buf API to see writes the ISP just made.
    dmabuf_sync(view.sync_fds, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);

    unsigned long jpeg_size = max_jpeg_size;
    const unsigned char* planes[3] = {view.y, view.u, view.v};
    int strides[3] = {view.y_stride, view.uv_stride, view.uv_stride};
    int compress_status = tjCompressFromYUVPlanes(jpeg_encoder, planes, static_cast<int>(out_width),
                                     strides, static_cast<int>(out_height),
                                     TJSAMP_420, &jpeg_buffer, &jpeg_size, kJpegQuality,
                                     TJFLAG_FASTDCT | TJFLAG_NOREALLOC);

    dmabuf_sync(view.sync_fds, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);

    if (compress_status == 0) {
      record = ovcs::framing::build_frame_record(
          static_cast<uint16_t>(out_width),
          static_cast<uint16_t>(out_height),
          capture_ns,
          jpeg_buffer, static_cast<size_t>(jpeg_size));
      if (!ovcs::framing::write_record(record.data(), record.size())) {
        g_stop.store(true);
      }
    } else {
      log_message(LOG_WARNING, "tjCompressFromYUVPlanes: %s",
                   tjGetErrorStr2(jpeg_encoder));
    }

    request->reuse(Request::ReuseBuffers);
    {
      std::lock_guard<std::mutex> lock(g_pending_mutex);
      if (!g_pending_controls.empty()) {
        request->controls().merge(g_pending_controls, ControlList::MergePolicy::OverwriteExisting);
        g_pending_controls.clear();
      }
    }
    camera->queueRequest(request);
  });

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
    tjDestroy(jpeg_encoder);
    camera->release();
    camera_manager.stop();
    return 1;
  }

  for (auto& request : requests) {
    if (camera->queueRequest(request.get()) != 0) {
      log_message(LOG_ERROR, "initial queueRequest failed");
      g_stop.store(true);
      break;
    }
  }

  while (!g_stop.load()) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }

  camera->stop();
  allocator.free(stream);
  camera->release();
  camera_manager.stop();
  if (jpeg_buffer) tjFree(jpeg_buffer);
  tjDestroy(jpeg_encoder);
  return 0;
}
