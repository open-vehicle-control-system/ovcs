#ifndef ABSTRACT_CRC_H
#define ABSTRACT_CRC_H

#include <Arduino.h>

class AbstractCrc {

  public:
    AbstractCrc(){};
    virtual uint32_t crc32(uint8_t data [], size_t size) = 0;
};

#endif