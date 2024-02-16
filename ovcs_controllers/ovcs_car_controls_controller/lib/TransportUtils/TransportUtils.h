#ifndef TransportUtils_h
#define TransportUtils_h

#include <Arduino.h>

boolean initializeTransport();
void sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
int receiveValidatedGear();

#endif