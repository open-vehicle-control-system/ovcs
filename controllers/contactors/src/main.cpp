#include <SPI.h>
#include <mcp2515.h>

#define CONTACTORS_STATUS_REQUEST_FRAME_ID 0x100
#define CONTACTORS_STATUS_REQUEST_FRAME_LENGTH 3

#define CONTACTORS_STATUS_FRAME_ID 0x101
#define CONTACTORS_STATUS_FRAME_LENGTH 3

#define CONTACTOR_STATUS_FRAME_FREQUENCY_MS 10

#define MAIN_NEGATIVE_CONTACTOR_RELAY_PIN 4
#define MAIN_POSITIVE_CONTACTOR_RELAY_PIN 8
#define PRECHARGE_CONTACTOR_RELAY_PIN 7

MCP2515 OVCS_CAN(10);

unsigned long sendTimestamp = 0;
unsigned long now = 0;

struct can_frame contactorsStatusRequestFrame;
struct can_frame contactorsStatusFrame;

int mainNegativeContactorRequestedState = 0;
int mainPositiveRequestedContactor = 0;
int prechargeContactorRequestedState = 0;

void receive_frame() {
  if (OVCS_CAN.readMessage(&contactorsStatusRequestFrame) == MCP2515::ERROR_OK) {
    mainNegativeContactorRequestedState = contactorsStatusRequestFrame.data[0];
    mainPositiveRequestedContactor = contactorsStatusRequestFrame.data[1];
    prechargeContactorRequestedState = contactorsStatusRequestFrame.data[2];
  } 
}

void actuate_relays() {
  digitalWrite(MAIN_NEGATIVE_CONTACTOR_RELAY_PIN, mainNegativeContactorRequestedState == 1 ? HIGH : LOW);
  digitalWrite(MAIN_POSITIVE_CONTACTOR_RELAY_PIN, mainPositiveRequestedContactor == 1 ? HIGH : LOW);
  digitalWrite(PRECHARGE_CONTACTOR_RELAY_PIN, prechargeContactorRequestedState == 1 ? HIGH : LOW);
}

void send_status() {
  now = millis();
  if (sendTimestamp + CONTACTOR_STATUS_FRAME_FREQUENCY_MS <= now) {
    sendTimestamp = now;
    contactorsStatusFrame.data[0] = digitalRead(MAIN_NEGATIVE_CONTACTOR_RELAY_PIN);
    contactorsStatusFrame.data[1] = digitalRead(MAIN_POSITIVE_CONTACTOR_RELAY_PIN);
    contactorsStatusFrame.data[2] = digitalRead(PRECHARGE_CONTACTOR_RELAY_PIN);
    OVCS_CAN.sendMessage(&contactorsStatusFrame);
  } 
}

void setup() {
  Serial.begin(9600);

  OVCS_CAN.reset();
  OVCS_CAN.setBitrate(CAN_500KBPS, MCP_8MHZ);
  OVCS_CAN.setFilterMask(MCP2515::MASK0,0,0x7FF);
  OVCS_CAN.setFilter(MCP2515::RXF0,0,CONTACTORS_STATUS_REQUEST_FRAME_ID);
  OVCS_CAN.setFilterMask(MCP2515::MASK1,0,0x7FF);
  OVCS_CAN.setNormalMode();

  pinMode(MAIN_NEGATIVE_CONTACTOR_RELAY_PIN, OUTPUT);
  pinMode(MAIN_POSITIVE_CONTACTOR_RELAY_PIN, OUTPUT);
  pinMode(PRECHARGE_CONTACTOR_RELAY_PIN, OUTPUT);

  contactorsStatusRequestFrame.can_id = CONTACTORS_STATUS_REQUEST_FRAME_ID;
  contactorsStatusRequestFrame.can_dlc = CONTACTORS_STATUS_REQUEST_FRAME_LENGTH;

  contactorsStatusFrame.can_id = CONTACTORS_STATUS_FRAME_ID;
  contactorsStatusFrame.can_dlc = CONTACTORS_STATUS_FRAME_LENGTH;

  actuate_relays();
}

void loop() {
  receive_frame();
  actuate_relays();
  send_status();
}

