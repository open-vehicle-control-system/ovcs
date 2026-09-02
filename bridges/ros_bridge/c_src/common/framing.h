// Shared framing helpers for the camera_capture Port binary.
// (Hailo inference uses the nx_hailo NIF, not a Port — see
// lib/ros_bridge/inference/hailo.ex.)
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

// Write one length-prefixed record to stdout. Flushes stdout so
// the Elixir side sees records promptly.
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
