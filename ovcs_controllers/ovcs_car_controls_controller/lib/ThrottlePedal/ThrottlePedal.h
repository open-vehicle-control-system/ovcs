#include <Arduino.h>

#define ANALOG_READ_RESOLUTION 14
#define MAX_ANALOG_READ_VALUE 16383
#define THROTTLE_PEDAL_PIN_1 A0
#define THROTTLE_PEDAL_PIN_2 A1

class ThrottlePedal{
    public:
        boolean initialize();
        int* readValues();
};