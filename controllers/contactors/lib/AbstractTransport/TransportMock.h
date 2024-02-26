#ifndef TRANSPORTMOCK_H
#define TRANSPORTMOCK_H
#include <AbstractTransport.h>

class TransportMock : public AbstractTransport{
    public:
        virtual boolean initialize();
        virtual void sendFrame(int mainNegativeRelayPin, int mainPositiveRelayPin, int prechargeRelayPin);
        virtual ContactorsRequestedStatuses pullContactorsStatuses();
};
#endif