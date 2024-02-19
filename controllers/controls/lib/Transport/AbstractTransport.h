#include <Arduino.h>

struct AbstractTransport{
    public:
        virtual boolean initialize() = 0;
        virtual void sendFrame(int, int, int, int) = 0;
        virtual int pullValidatedGear() = 0;
};