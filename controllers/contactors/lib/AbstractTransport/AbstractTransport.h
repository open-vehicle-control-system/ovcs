#ifndef ABSTRACTTRANSPORT_H
#define ABSTRACTTRANSPORT_H
#include <Arduino.h>

struct ContactorsRequestedStatuses{
    int mainNegativeContactorRequestedState, mainPositiveRequestedContactor, prechargeContactorRequestedState;
};

struct ContactorsStatuses{
    int mainNegativeStatus, mainPositiveStatus, prechargeStatus;
};

struct AbstractTransport{
    public:
        virtual boolean initialize() = 0;
        virtual void sendFrame(int, int, int) = 0;
        virtual ContactorsRequestedStatuses pullContactorsStatuses() = 0;
};
#endif