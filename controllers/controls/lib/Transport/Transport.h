#ifndef TRANSPORT_H
#define TRANSPORT_H
#include <AbstractTransport.h>

class Transport : public AbstractTransport{
    public:
        boolean initialize();
        void sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
        void sendKeepAlive(int status);
        int pullValidatedGear();
};
#endif