#include <MockBoard.h>

bool MockBoard::begin() { return true; };

void MockBoard::pinMode(uint8_t pin, PinMode mode) {};

void MockBoard::digitalWrite(uint8_t pin, PinStatus status) {};

uint8_t MockBoard::digitalRead(uint8_t pin) { return 1; };