#ifndef TransportUtils_h
#define TransportUtils_h

#include <Arduino.h>

class Transport{

    public:
        boolean static initialize();
        void static sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
        int static pullValidatedGear();
};

#endif