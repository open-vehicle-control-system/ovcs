#include <controller.h>

Controller controller;

void setup()
{
  uint16_t coucou = 10205;
  controller.setup();

  Serial.println(0b10011111011101);
   Serial.println(0b10011111011101, BIN);
  Serial.println((coucou & 0b00111000) >> 3, BIN);
  Serial.println(coucou & 0b00000111, BIN);

  Serial.println(coucou >> 6 & 0b11111111, BIN);

};

void loop () {
  controller.loop();
};
