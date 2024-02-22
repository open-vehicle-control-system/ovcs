#ifndef OVCSMCP2515_H
#define OVCSMCP2515_H
#include <AbstractTransport.h>

class OvcsMcp2515 : public AbstractTransport{
    public:
        boolean initialize();
        void sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
        void sendKeepAlive(int status);
        int pullValidatedGear();
};
#endif