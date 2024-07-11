#include <Controller.h>
#include <MosfetBoard.h>
#include <MainBoard.h>

#define MOSFET_1_ADDRESS 0x27
#define MOSFET_2_ADDRESS 0x26

MainBoard mainBoard      = MainBoard();
MosfetBoard mosfetBoard1 = MosfetBoard(MOSFET_1_ADDRESS);
MosfetBoard mosfetBoard2 = MosfetBoard(MOSFET_2_ADDRESS);

Controller controller = Controller(&mainBoard, &mosfetBoard1, &mosfetBoard2);

void setup() {
  controller.setup();
};

void loop () {
  controller.loop();
};
