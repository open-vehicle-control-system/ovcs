#ifndef MAIN_BOARD_H
#define MAIN_BOARD_H

#include <AbstractBoard.h>
#include <MCP23008.h>
#define I2C_CLOCK_FREQUENCY 100000

class MainBoard: public AbstractBoard {
  public:
    bool begin();
    void pinMode(uint8_t pin, uint8_t mode);
    void digitalWrite(uint8_t pin, uint8_t value);
    uint8_t digitalRead(uint8_t pin);
};

#endif