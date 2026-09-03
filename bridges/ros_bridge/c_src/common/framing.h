// Shared framing helpers for the Port binaries (camera_capture,
// hailo_detect).
//
// The wire format on stdin/stdout is `Port.open(..., {:packet, 4})`
// on the Elixir side — a 4-byte **big-endian** length prefix in
// front of each record. These helpers wrap the prefix handling so
// each main.cpp only deals with whole records.
//
// Inside each record the tag + payload uses little-endian for
// scalars and matches the Elixir parsers byte-for-byte (see
// lib/ros_bridge/camera/lib_camera.ex).

#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace ovcs::framing {

// Read one length-prefixed record from stdin into `out`. Returns
// false on EOF or read error — callers should treat that as a clean
// shutdown signal (the BEAM closing the Port closes stdin).
bool read_record(std::vector<uint8_t>& out);

// Redirect subsequent `write_record` calls to `fd` instead of
// stdout. `hailo_detect` needs this: libhailort's logger writes to
// stdout, and a stray `[info]` line in the middle of a record turns
// into a bogus 4-byte length prefix and desynchronises the Port for
// good. The fix is to hand the real stdout to the framing layer and
// point fd 1 at stderr before HailoRT is ever touched:
//
//     int records = dup(STDOUT_FILENO);
//     dup2(STDERR_FILENO, STDOUT_FILENO);
//     ovcs::framing::set_output_fd(records);
//
// Callers that never initialise a chatty library (camera_capture)
// can ignore this and keep the stdout default.
void set_output_fd(int fd);

// Write one length-prefixed record to the output fd (stdout unless
// `set_output_fd` said otherwise).
bool write_record(const uint8_t* data, size_t len);

// Convenience: build the FRAME record payload (tag = 1) used by
// camera_capture. Mirrors the parser in
// `RosBridge.Camera.LibCamera.parse_record/1`.
std::vector<uint8_t> build_frame_record(
    uint16_t width,
    uint16_t height,
    int64_t capture_ns,
    const uint8_t* jpeg, size_t jpeg_len);

}  // namespace ovcs::framing
