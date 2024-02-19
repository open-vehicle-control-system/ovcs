#include <Arduino.h>
#include <GearConstants.h>

class GearSelector{
    public:
        boolean initialize();
        int getGearPosition();
};