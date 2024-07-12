#ifndef MOCK_CRC_H
#define MOCK_CRC_H

#include <AbstractCrc.h>

class MockCrc: public AbstractCrc {
  public:
    uint32_t crc32(uint8_t data [], size_t size);
};

#endif