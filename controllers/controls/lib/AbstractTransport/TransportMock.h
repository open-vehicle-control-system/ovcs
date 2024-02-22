#ifndef TRANSPORTMOCK_H
#define TRANSPORTMOCK_H
#include <AbstractTransport.h>

class TransportMock : public AbstractTransport{
    public:
        virtual boolean initialize();
        virtual void sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
        virtual void sendKeepAlive(int status);
        virtual int pullValidatedGear();
};
#endif