#ifndef InitializationHelpers_h
#define InitializationHelpers_h

#define GEAR_DRIVE_PIN 2
#define DRIVE_INDICATOR_PIN 6
#define GEAR_NEUTRAL_PIN 3
#define NEUTRAL_INDICATOR_PIN 7
#define GEAR_REVERSE_PIN 4
#define REVERSE_INDICATOR_PIN 8
#define GEAR_PARKING_PIN 5
#define PARKING_INDICATOR_PIN 9
#define DRIVE 0
#define NEUTRAL 1
#define REVERSE 2
#define PARKING 3

#include <Arduino.h>
#include <TransportUtils.h>

class InitializationHelpers{

    public:
        boolean static initializeController();
        boolean static initializeGearSelector();
        void static resetIndicators();
};

#endif