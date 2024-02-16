#include <ThrottlePedal.h>

boolean ThrottlePedal::initialize(){
    pinMode(THROTTLE_PEDAL_PIN_1, INPUT);
    pinMode(THROTTLE_PEDAL_PIN_2, INPUT);
    return true;
};

int* ThrottlePedal::readValues(){
    analogReadResolution(ANALOG_READ_RESOLUTION); // Set resolution to 14bits (max 16383) instead of 10bits (max 1023)
    int values[2];
    values[0] = analogRead(THROTTLE_PEDAL_PIN_1);
    values[1] = analogRead(THROTTLE_PEDAL_PIN_2);
    return values;
};