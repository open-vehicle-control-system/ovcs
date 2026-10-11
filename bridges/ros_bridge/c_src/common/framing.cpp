#include "framing.h"

#include <arpa/inet.h>  // htonl/ntohl
#include <cstring>
#include <mutex>
#include <unistd.h>

namespace ovcs::framing {

namespace {

constexpr uint8_t kTagFrame = 1;
constexpr uint8_t kTagLog = 2;
constexpr uint8_t kTagMetadata = 3;

bool read_exact(int fd, void* buffer, size_t length) {
  uint8_t* cursor = static_cast<uint8_t*>(buffer);
  while (length > 0) {
    ssize_t transferred = ::read(fd, cursor, length);
    if (transferred <= 0) return false;
    cursor += static_cast<size_t>(transferred);
    length -= static_cast<size_t>(transferred);
  }
  return true;
}

bool write_exact(int fd, const void* buffer, size_t length) {
  const uint8_t* cursor = static_cast<const uint8_t*>(buffer);
  while (length > 0) {
    ssize_t transferred = ::write(fd, cursor, length);
    if (transferred <= 0) return false;
    cursor += static_cast<size_t>(transferred);
    length -= static_cast<size_t>(transferred);
  }
  return true;
}

int output_fd = STDOUT_FILENO;

}  // namespace

void set_output_fd(int fd) { output_fd = fd; }

bool read_record(std::vector<uint8_t>& out) {
  uint32_t big_endian_length = 0;
  if (!read_exact(STDIN_FILENO, &big_endian_length, sizeof(big_endian_length))) return false;
  uint32_t length = ntohl(big_endian_length);
  out.resize(length);
  if (length == 0) return true;
  return read_exact(STDIN_FILENO, out.data(), length);
}

bool write_record(const uint8_t* data, size_t length) {
  // A record is two writes: interleaving two threads' would corrupt
  // the stream.
  static std::mutex write_mutex;
  std::lock_guard<std::mutex> lock(write_mutex);
  uint32_t big_endian_length = htonl(static_cast<uint32_t>(length));
  if (!write_exact(output_fd, &big_endian_length, sizeof(big_endian_length))) return false;
  if (length > 0 && !write_exact(output_fd, data, length)) return false;
  return true;
}

std::vector<uint8_t> build_log_record(uint8_t level, const std::string& message) {
  std::vector<uint8_t> out;
  out.reserve(2 + message.size());
  out.push_back(kTagLog);
  out.push_back(level);
  out.insert(out.end(), message.begin(), message.end());
  return out;
}

std::vector<uint8_t> build_metadata_record(int64_t capture_ns, uint8_t present,
                                           const double (&values)[kMetadataFields]) {
  std::vector<uint8_t> out(2 + sizeof(capture_ns) + sizeof(values));
  out[0] = kTagMetadata;
  out[1] = present;
  std::memcpy(out.data() + 2, &capture_ns, sizeof(capture_ns));
  std::memcpy(out.data() + 2 + sizeof(capture_ns), values, sizeof(values));
  return out;
}

std::vector<uint8_t> build_frame_record(uint16_t width, uint16_t height,
                                        int64_t capture_ns,
                                        const uint8_t* jpeg, size_t jpeg_length) {
  std::vector<uint8_t> out;
  out.reserve(1 + 2 + 2 + 8 + 4 + jpeg_length);

  out.push_back(kTagFrame);

  auto append = [&](const void* p, size_t n) {
    const uint8_t* b = static_cast<const uint8_t*>(p);
    out.insert(out.end(), b, b + n);
  };

  append(&width, sizeof(width));
  append(&height, sizeof(height));
  append(&capture_ns, sizeof(capture_ns));
  uint32_t jpeg_length32 = static_cast<uint32_t>(jpeg_length);
  append(&jpeg_length32, sizeof(jpeg_length32));
  if (jpeg_length > 0) append(jpeg, jpeg_length);

  return out;
}

}  // namespace ovcs::framing
