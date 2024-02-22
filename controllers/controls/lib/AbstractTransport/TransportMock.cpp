#include <TransportMock.h>

boolean TransportMock::initialize(){
    return true;
}

void TransportMock::sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear){
}

void TransportMock::sendKeepAlive(int status){
}

int TransportMock::pullValidatedGear(){
    return 3;
}
