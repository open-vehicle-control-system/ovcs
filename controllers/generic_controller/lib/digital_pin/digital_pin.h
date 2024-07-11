#ifndef DIGITAL_PIN_H
#define DIGITAL_PIN_H

#include <Arduino.h>
#include <MCP23008.h>

#define MAIN_BOARD_ID 0
#define MOSFET_0_ID 1
#define MOSFET_1_ID 2

#define DIGITAL_PIN_DISABLED 0
#define DIGITAL_PIN_READ_ONLY 1
#define DIGITAL_PIN_WRITE_ONLY 2
#define DIGITAL_PIN_READ_WRITE 3
#define MOSFET_1_ADDRESS 0x27
#define MOSFET_2_ADDRESS 0x26

static MCP23008 MOSFETBoard1 = MCP23008(MOSFET_1_ADDRESS);
static MCP23008 MOSFETBoard2 = MCP23008(MOSFET_2_ADDRESS);

const uint8_t digitalPinMapping [21][2] = {
  {MAIN_BOARD_ID, D0},
  {MAIN_BOARD_ID, D1},
  {MAIN_BOARD_ID, D4},
  {MAIN_BOARD_ID, D7},
  {MAIN_BOARD_ID, D8},
  {MOSFET_0_ID, 0},
  {MOSFET_0_ID, 1},
  {MOSFET_0_ID, 2},
  {MOSFET_0_ID, 3},
  {MOSFET_0_ID, 4},
  {MOSFET_0_ID, 5},
  {MOSFET_0_ID, 6},
  {MOSFET_0_ID, 7},
  {MOSFET_1_ID, 0},
  {MOSFET_1_ID, 1},
  {MOSFET_1_ID, 2},
  {MOSFET_1_ID, 3},
  {MOSFET_1_ID, 4},
  {MOSFET_1_ID, 5},
  {MOSFET_1_ID, 6},
  {MOSFET_1_ID, 7},
};

class DigitalPin {
  public:
    DigitalPin() {};
    DigitalPin(uint8_t initialStatus, uint8_t initialBoard, uint8_t initialPhysicalPin) {
      status       = initialStatus;
      board        = initialBoard;
      physicalPin = initialPhysicalPin;
      initPhysicalPin();
    };
    void writeIfAllowed(bool value) ;
    uint8_t readIfAllowed();
    bool writeable();
    bool readable();

  private:
    uint8_t status;
    uint8_t board;
    uint8_t physicalPin;

    void initPhysicalPin();
    uint8_t physicalPinMode();

};

#endif