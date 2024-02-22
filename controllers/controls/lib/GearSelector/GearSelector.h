#ifndef GEARSELECTOR_H
#define GEARSELECTOR_H
#include <Arduino.h>
#include <GearConstants.h>

class GearSelector{
    public:
        boolean initialize();
        int getGearPosition();
};
#endif