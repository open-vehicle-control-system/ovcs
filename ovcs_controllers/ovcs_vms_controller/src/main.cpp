#include <SPI.h>
#include <mcp2515.h>

#define VMS_RELAYS_STATUS_REQUEST_FRAME_ID 0x110
#define VMS_RELAYS_STATUS_REQUEST_FRAME_LENGTH 1

#define VMS_RELAYS_STATUS_FRAME_ID 0x111
#define VMS_RELAYS_STATUS_FRAME_LENGTH 1

#define VMS_RELAYS_STATUS_FRAME_FREQUENCY_MS 10

#define INVERTER_RELAY_PIN 4

MCP2515 OVCS_CAN(10);

unsigned long sendTimestamp = 0;
unsigned long now = 0;

struct can_frame vmsRelaysStatusRequestFrame;
struct can_frame vmsRelaysStatusFrame;

int inverterRelayRequestedState = 0;

void receive_frame() {
  if (OVCS_CAN.readMessage(&vmsRelaysStatusRequestFrame) == MCP2515::ERROR_OK) {
    inverterRelayRequestedState = vmsRelaysStatusRequestFrame.data[0];
  } 
}

void actuate_relays() {
  digitalWrite(INVERTER_RELAY_PIN, inverterRelayRequestedState == 1 ? HIGH : LOW);
}

void send_status() {
  now = millis();
  if (sendTimestamp + VMS_RELAYS_STATUS_FRAME_FREQUENCY_MS <= now) {
    sendTimestamp = now;
    vmsRelaysStatusFrame.data[0] = digitalRead(INVERTER_RELAY_PIN);
    OVCS_CAN.sendMessage(&vmsRelaysStatusFrame);
  } 
}

void setup() {
  Serial.begin(9600);

  OVCS_CAN.reset();
  OVCS_CAN.setBitrate(CAN_500KBPS, MCP_8MHZ);
  OVCS_CAN.setFilterMask(MCP2515::MASK0, 0, 0x7FF);
  OVCS_CAN.setFilter(MCP2515::RXF0, 0, VMS_RELAYS_STATUS_REQUEST_FRAME_ID);
  OVCS_CAN.setFilterMask(MCP2515::MASK1, 0, 0x7FF);
  OVCS_CAN.setNormalMode();

  pinMode(INVERTER_RELAY_PIN, OUTPUT);

  vmsRelaysStatusRequestFrame.can_id = VMS_RELAYS_STATUS_REQUEST_FRAME_ID;
  vmsRelaysStatusRequestFrame.can_dlc = VMS_RELAYS_STATUS_REQUEST_FRAME_LENGTH;

  vmsRelaysStatusFrame.can_id = VMS_RELAYS_STATUS_FRAME_ID;
  vmsRelaysStatusFrame.can_dlc = VMS_RELAYS_STATUS_FRAME_LENGTH;

  actuate_relays();
}

void loop() {
  receive_frame();
  actuate_relays();
  send_status();
}

