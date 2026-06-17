#include "framing.h"

#include <arpa/inet.h>  // htonl/ntohl
#include <cstring>
#include <unistd.h>

namespace ovcs::framing {

namespace {

bool read_exact(int fd, void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  while (len > 0) {
    ssize_t n = ::read(fd, p, len);
    if (n <= 0) return false;
    p += static_cast<size_t>(n);
    len -= static_cast<size_t>(n);
  }
  return true;
}

bool write_exact(int fd, const void* buf, size_t len) {
  const uint8_t* p = static_cast<const uint8_t*>(buf);
  while (len > 0) {
    ssize_t n = ::write(fd, p, len);
    if (n <= 0) return false;
    p += static_cast<size_t>(n);
    len -= static_cast<size_t>(n);
  }
  return true;
}

}  // namespace

bool read_record(std::vector<uint8_t>& out) {
  uint32_t be_len = 0;
  if (!read_exact(STDIN_FILENO, &be_len, sizeof(be_len))) return false;
  uint32_t len = ntohl(be_len);
  out.resize(len);
  if (len == 0) return true;
  return read_exact(STDIN_FILENO, out.data(), len);
}

bool write_record(const uint8_t* data, size_t len) {
  uint32_t be_len = htonl(static_cast<uint32_t>(len));
  if (!write_exact(STDOUT_FILENO, &be_len, sizeof(be_len))) return false;
  if (len > 0 && !write_exact(STDOUT_FILENO, data, len)) return false;
  // No fflush — we use the raw fd (write()), not stdio.
  return true;
}

std::vector<uint8_t> build_frame_record(uint16_t width, uint16_t height,
                                        int64_t capture_ns,
                                        const uint8_t* jpeg, size_t jpeg_len) {
  std::vector<uint8_t> out;
  out.reserve(1 + 2 + 2 + 8 + 4 + jpeg_len);

  // tag = 1 (FRAME)
  out.push_back(1);

  auto append = [&](const void* p, size_t n) {
    const uint8_t* b = static_cast<const uint8_t*>(p);
    out.insert(out.end(), b, b + n);
  };

  append(&width, sizeof(width));
  append(&height, sizeof(height));
  append(&capture_ns, sizeof(capture_ns));
  uint32_t jl = static_cast<uint32_t>(jpeg_len);
  append(&jl, sizeof(jl));
  if (jpeg_len > 0) append(jpeg, jpeg_len);

  return out;
}

}  // namespace ovcs::framing
