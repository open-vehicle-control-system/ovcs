#include <MockBoard.h>

bool MockBoard::begin() { return true; };

void MockBoard::pinMode(uint8_t pin, uint8_t mode) {};

void MockBoard::digitalWrite(uint8_t pin, uint8_t value) {};

uint8_t MockBoard::digitalRead(uint8_t pin) { return 0; };