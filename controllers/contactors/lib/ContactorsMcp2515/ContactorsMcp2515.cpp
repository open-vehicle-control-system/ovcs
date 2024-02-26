#include <Arduino.h>
#include <SPI.h>
#include <mcp2515.h>
#include <ContactorsMcp2515.h>

#define CAN_PIN 10

#define CONTACTORS_STATUS_REQUEST_FRAME_ID 0x100
#define CONTACTORS_STATUS_REQUEST_FRAME_LENGTH 3

#define CONTACTORS_STATUS_FRAME_ID 0x101
#define CONTACTORS_STATUS_FRAME_LENGTH 3

#define CONTACTOR_STATUS_FRAME_FREQUENCY_MS 10

can_frame contactorsStatusFrame;
can_frame contactorsStatusRequestFrame;

unsigned long sendTimestamp = 0;
unsigned long now = 0;

MCP2515 OVCS_CAN(CAN_PIN);

boolean ContactorsMcp2515::initialize(){
    OVCS_CAN.reset();
    OVCS_CAN.setBitrate(CAN_500KBPS, MCP_8MHZ);
    OVCS_CAN.setFilterMask(MCP2515::MASK0,0,0x7FF);
    OVCS_CAN.setFilter(MCP2515::RXF0,0,CONTACTORS_STATUS_REQUEST_FRAME_ID);
    OVCS_CAN.setFilterMask(MCP2515::MASK1,0,0x7FF);
    OVCS_CAN.setNormalMode();
    contactorsStatusRequestFrame.can_id = CONTACTORS_STATUS_REQUEST_FRAME_ID;
    contactorsStatusRequestFrame.can_dlc = CONTACTORS_STATUS_REQUEST_FRAME_LENGTH;
    contactorsStatusFrame.can_id = CONTACTORS_STATUS_FRAME_ID;
    contactorsStatusFrame.can_dlc = CONTACTORS_STATUS_FRAME_LENGTH;
    return OVCS_CAN.checkError();
}

ContactorsRequestedStatuses ContactorsMcp2515::pullContactorsStatuses(){
    if (OVCS_CAN.readMessage(&contactorsStatusRequestFrame) == MCP2515::ERROR_OK) {
        ContactorsRequestedStatuses statuses;
        statuses.mainNegativeContactorRequestedState = contactorsStatusRequestFrame.data[0];
        statuses.mainPositiveRequestedContactor      = contactorsStatusRequestFrame.data[1];
        statuses.prechargeContactorRequestedState    = contactorsStatusRequestFrame.data[2];
        return statuses;
    }
}

void ContactorsMcp2515::sendFrame(int mainNegativeRelayPin, int mainPositiveRelayPin, int prechargeRelayPin){
    now = millis();
    if (sendTimestamp + CONTACTOR_STATUS_FRAME_FREQUENCY_MS <= now) {
        sendTimestamp = now;
        contactorsStatusFrame.data[0] = mainNegativeRelayPin;
        contactorsStatusFrame.data[1] = mainPositiveRelayPin;
        contactorsStatusFrame.data[2] = prechargeRelayPin;
        OVCS_CAN.sendMessage(&contactorsStatusFrame);
    } 
}