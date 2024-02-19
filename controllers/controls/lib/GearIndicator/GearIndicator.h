#ifndef GEARINDICATOR_H
#define GEARINDICATOR_H
#include <Arduino.h>
#include <GearConstants.h>
#include <AbstractTransport.h>

class GearIndicator{
    public:
        AbstractTransport* _transport;
        GearIndicator(AbstractTransport* transport);
        boolean initialize();
        int getValidatedGearPosition();
        void indicateGearPosition(int gear);
    private:
        void reset();
};
#endif