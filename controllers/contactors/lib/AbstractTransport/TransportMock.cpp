#include <TransportMock.h>

boolean TransportMock::initialize(){
    return true;
}

void TransportMock::sendFrame(int mainNegativeRelayPin, int mainPositiveRelayPin, int prechargeRelayPin){
}

ContactorsRequestedStatuses TransportMock::pullContactorsStatuses(){
    ContactorsRequestedStatuses statuses;
    return statuses;
}
