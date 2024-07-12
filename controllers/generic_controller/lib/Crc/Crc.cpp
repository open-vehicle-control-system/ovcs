#include <Crc.h>

uint32_t Crc::crc32(uint8_t data [], size_t size) {
  return CRC32::calculate(data, size);
};