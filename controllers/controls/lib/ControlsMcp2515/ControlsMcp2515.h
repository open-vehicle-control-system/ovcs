#ifndef CONTROLSMCP2515_H
#define CONTROLSMCP2515_H
#include <AbstractTransport.h>

class ControlsMcp2515 : public AbstractTransport{
    public:
        boolean initialize();
        void sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
        void sendKeepAlive(int status);
        int pullValidatedGear();
};
#endif