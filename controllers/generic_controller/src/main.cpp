#include <Controller.h>
#include <ExpansionBoard.h>
#include <MainBoard.h>
#include <Arduino.h>
#include <Crc.h>

#define EXPANSION_BOARD_ADDRESS_1 0x20
#define EXPANSION_BOARD_ADDRESS_2 0x21

MainBoard      mainBoard        = MainBoard();
ExpansionBoard expansionBoard1  = ExpansionBoard(EXPANSION_BOARD_ADDRESS_1);
ExpansionBoard expansionBoard2  = ExpansionBoard(EXPANSION_BOARD_ADDRESS_2);
Crc            configurationCrc = Crc();
SerialTransfer serialTransfer   = SerialTransfer();

Controller controller = Controller(
  &mainBoard,
  &expansionBoard1,
  &expansionBoard2,
  &configurationCrc,
  &serialTransfer
);

void setup() {
  controller.setup();
};

void loop () {
  controller.loop();
};
