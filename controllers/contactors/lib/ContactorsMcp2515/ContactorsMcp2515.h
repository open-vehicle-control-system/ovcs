#ifndef CONTACTORSMCP2515_H
#define CONTACTORSMCP2515_H
#include <AbstractTransport.h>

class ContactorsMcp2515 : public AbstractTransport{
    public:
        boolean initialize();
        void sendFrame(int mainNegativeRelayPin, int mainPositiveRelayPin, int prechargeRelayPin);
        ContactorsRequestedStatuses pullContactorsStatuses();
};
#endif