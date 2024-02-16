#include <Arduino.h>
#include <Transport.h>
#include <GearConstants.h>

class GearIndicator{
    public:
        Transport _transport;
        GearIndicator(Transport transport);
        boolean initialize();
        int getValidatedGearPosition();
        void indicateGearPosition(int gear);
        void reset();
};