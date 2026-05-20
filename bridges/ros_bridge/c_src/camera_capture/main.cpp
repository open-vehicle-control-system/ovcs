// camera_capture — opens a single libcamera CSI sensor and writes
// JPEG frames to stdout in the OVCS port framing protocol (see
// ../common/framing.h).
//
// **STATUS: SKELETON.** The framing protocol + argv parsing + the
// stdin-as-shutdown-signal pattern are implemented and correct.
// The libcamera integration is stubbed with a TODO — opening the
// sensor and pumping requests through the camera manager needs to
// be developed against actual Pi 5 hardware (libcamera's API is
// callback-heavy and the right pattern depends on the kernel /
// libcamera versions shipped by nerves_system_rpi5 at the time
// this is finished). For now the binary emits a small canned
// 1×1 JPEG at the requested fps so the Elixir side can be smoke
// tested end-to-end on the device.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include "framing.h"

namespace {

struct Args {
  int camera_id = 0;
  int width = 1280;
  int height = 720;
  int fps = 30;
};

bool parse_args(int argc, char** argv, Args& out) {
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : nullptr; };
    if (a == "--camera" && next()) out.camera_id = std::atoi(argv[i]);
    else if (a == "--width" && next()) out.width = std::atoi(argv[i]);
    else if (a == "--height" && next()) out.height = std::atoi(argv[i]);
    else if (a == "--fps" && next()) out.fps = std::atoi(argv[i]);
    else { std::fprintf(stderr, "camera_capture: unknown arg %s\n", a.c_str()); return false; }
  }
  return true;
}

// Minimal valid 1×1 JPEG — same shape as the Elixir Dummy driver.
// Used until the libcamera integration lands so we exercise the
// framing protocol end-to-end on real hardware.
const std::vector<uint8_t> kStubJpeg = {
  0xFF,0xD8,0xFF,0xE0,0x00,0x10,'J','F','I','F',0x00,0x01,0x01,0x00,0x00,0x01,
  0x00,0x01,0x00,0x00,0xFF,0xDB,0x00,0x43,0x00,0x08,0x06,0x06,0x07,0x06,0x05,0x08,
  0x07,0x07,0x07,0x09,0x09,0x08,0x0A,0x0C,0x14,0x0D,0x0C,0x0B,0x0B,0x0C,0x19,0x12,
  0x13,0x0F,0x14,0x1D,0x1A,0x1F,0x1E,0x1D,0x1A,0x1C,0x1C,0x20,0x24,0x2E,0x27,0x20,
  0x22,0x2C,0x23,0x1C,0x1C,0x28,0x37,0x29,0x2C,0x30,0x31,0x34,0x34,0x34,0x1F,0x27,
  0x39,0x3D,0x38,0x32,0x3C,0x2E,0x33,0x34,0x32,0xFF,0xC0,0x00,0x0B,0x08,0x00,0x01,
  0x00,0x01,0x01,0x01,0x11,0x00,0xFF,0xC4,0x00,0x1F,0x00,0x00,0x01,0x05,0x01,0x01,
  0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,
  0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0xFF,0xDA,0x00,0x08,0x01,0x01,0x00,0x00,0x3F,
  0x00,0xFB,0xD0,0xFF,0xD9
};

std::atomic<bool> g_stop{false};

// Watch stdin in a background thread; when stdin closes (the BEAM
// closes the Port) flip the stop flag.
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

}  // namespace

int main(int argc, char** argv) {
  Args args;
  if (!parse_args(argc, argv, args)) return 2;

  std::fprintf(stderr,
               "camera_capture: camera=%d %dx%d @%d fps (libcamera integration TBD — emitting stub frames)\n",
               args.camera_id, args.width, args.height, args.fps);

  std::thread watcher(stdin_watcher);
  watcher.detach();

  // TODO(perception): replace this stub loop with the real
  // libcamera capture pipeline:
  //   1. CameraManager::instance()->start()
  //   2. acquire(cameras()[args.camera_id])
  //   3. generateConfiguration({StreamRole::VideoRecording}) at
  //      args.width × args.height; pick MJPEG / YUV420 + JPEG
  //      encoder on the ISP.
  //   4. queueRequest loop, on requestComplete emit the FRAME
  //      record using build_frame_record(...) + write_record(...).
  //   5. honour g_stop for clean shutdown.
  const auto period_us = static_cast<int>(1'000'000.0 / std::max(args.fps, 1));
  while (!g_stop.load()) {
    auto record = ovcs::framing::build_frame_record(
        static_cast<uint16_t>(args.width),
        static_cast<uint16_t>(args.height),
        monotonic_ns(),
        kStubJpeg.data(), kStubJpeg.size());

    if (!ovcs::framing::write_record(record.data(), record.size())) break;
    ::usleep(period_us);
  }

  return 0;
}
