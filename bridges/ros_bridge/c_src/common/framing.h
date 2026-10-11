// {:packet, 4} framing for the Port binaries: a big-endian length prefix
// per record. Record scalars are little-endian and match the Elixir parsers
// byte for byte (lib/ros_bridge/camera/lib_camera.ex).

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

// Redirect `write_record` to `fd`. A library that logs to stdout would
// corrupt the framing: hand the real stdout here and point fd 1 at stderr
// before initialising it (see hailo_detect's main).
void set_output_fd(int fd);

// Write one length-prefixed record to the output fd (stdout unless
// `set_output_fd` said otherwise). Safe to call from several threads.
bool write_record(const uint8_t* data, size_t length);

// A LOG record (tag = 2): one message for the BEAM's logger.
// Levels: 0 info, 1 warning, 2 error. Mirrors the parser in
// `RosBridge.Camera.LibCamera`.
std::vector<uint8_t> build_log_record(uint8_t level, const std::string& message);

// A METADATA record (tag = 3) for the frame taken at `capture_ns`: bit i of
// `present` is set when values[i] was reported. Mirrors the parser in
// `RosBridge.Camera.LibCamera`.
constexpr size_t kMetadataFields = 8;
std::vector<uint8_t> build_metadata_record(int64_t capture_ns, uint8_t present,
                                           const double (&values)[kMetadataFields]);

// A FRAME record (tag = 1). Mirrors the parser in
// `RosBridge.Camera.LibCamera.parse_record/1`.
std::vector<uint8_t> build_frame_record(
    uint16_t width,
    uint16_t height,
    int64_t capture_ns,
    const uint8_t* jpeg, size_t jpeg_length);

}  // namespace ovcs::framing
