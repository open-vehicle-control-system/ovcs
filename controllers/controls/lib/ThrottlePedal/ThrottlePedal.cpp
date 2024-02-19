#include <ThrottlePedal.h>

boolean ThrottlePedal::initialize(){
    pinMode(THROTTLE_PEDAL_PIN_1, INPUT);
    pinMode(THROTTLE_PEDAL_PIN_2, INPUT);
    return true;
};

AnalogValues ThrottlePedal::readValues(){
    analogReadResolution(ANALOG_READ_RESOLUTION); // Set resolution to 14bits (max 16383) instead of 10bits (max 1023)
    AnalogValues values;
    values.pin_1 = analogRead(THROTTLE_PEDAL_PIN_1);
    values.pin_2 = analogRead(THROTTLE_PEDAL_PIN_2);
    return values;
};