#ifndef VMS_H
#define VMS_H

#include <Arduino.h>

enum VmsStatus {
    OK = 0,
    RESETTING = 1,
    FAILURE = 0xFF
};

struct Vms {
    VmsStatus status = OK;
    bool readyToDrive = false;
    uint8_t counter = 0;
};

#endif
