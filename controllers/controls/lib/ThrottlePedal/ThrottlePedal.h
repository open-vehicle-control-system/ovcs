#ifndef THROTTLEPEDAL_H
#define THROTTLEPEDAL_H

#include <Arduino.h>

#define ANALOG_READ_RESOLUTION 14
#define MAX_ANALOG_READ_VALUE 16383
#define THROTTLE_PEDAL_PIN_1 A0
#define THROTTLE_PEDAL_PIN_2 A1

struct AnalogValues{
    int pin_1, pin_2;
};

class ThrottlePedal{
    public:
        boolean initialize();
        AnalogValues readValues();
};
#endif
