#include <AbstractTransport.h>

class Transport : AbstractTransport{
    public:
        boolean initialize();
        void sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear);
        int pullValidatedGear();
};