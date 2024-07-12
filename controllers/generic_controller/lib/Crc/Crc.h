#ifndef CRC_H
#define CRC_H

#include <AbstractCrc.h>
#include <CRC32.h>

class Crc: public AbstractCrc {
  public:
    uint32_t crc32(uint8_t data [], size_t size);
};

#endif