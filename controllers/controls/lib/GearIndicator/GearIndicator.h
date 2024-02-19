#include <Arduino.h>
#include <GearConstants.h>
#include <Transport.h>

class GearIndicator{
    public:
        Transport _transport;
        GearIndicator(Transport transport);
        boolean initialize();
        int getValidatedGearPosition();
        void indicateGearPosition(int gear);
        void reset();
};