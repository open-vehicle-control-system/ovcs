#ifndef TRANSPORTMOCK_H
#define TRANSPORTMOCK_H
#include <AbstractTransport.h>

class TransportMock : public AbstractTransport{
    public:
        boolean initialize();
        void sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
        int pullValidatedGear();
};
#endif