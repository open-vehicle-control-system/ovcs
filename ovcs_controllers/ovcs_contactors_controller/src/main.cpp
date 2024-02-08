#include <SPI.h>
#include <mcp2515.h>

struct can_frame receivedCanMessage;
MCP2515 can_0(10);
struct can_frame sentCanMessage;
unsigned long sendingTimestamp = 0;
unsigned long frequency = 10;
unsigned long now = 0;
struct can_frame contactorStateRequestFrame;
struct can_frame contactorStatusFrame;
int mainNegativeContactorRequestedState = 0;
int mainPositiveRequestedContactor = 0;
int prechargeContactorRequestedState = 0;


int main_negative_contactor_relay = 4;
int main_positive_contactor_relay = 7;
int precharge_contactor_relay = 8;

void receive_frame() {
  if (can_0.readMessage(&contactorStateRequestFrame) == MCP2515::ERROR_OK) {
    Serial.print(contactorStateRequestFrame.can_id, HEX); // print ID
    
    for (int i = 0; i<contactorStateRequestFrame.can_dlc; i++)  {  // print the data
      Serial.print(receivedCanMessage.data[i],HEX);
      Serial.print(" ");
    }
    Serial.println();  
  } 
}

void actuate_relays() {
  //digitalWrite(relay_1, HIGH);
}

void send_status() {
  now = millis();
  if (sendingTimestamp + frequency <= now) {
    sendingTimestamp = now;
    contactorStatusFrame.data[0] = 0;
    contactorStatusFrame.data[1] = 0;
    contactorStatusFrame.data[2] = 0;
    can_0.sendMessage(&contactorStatusFrame);
  } 
}

void setup() {
  Serial.begin(9600);

  can_0.reset();
  can_0.setBitrate(CAN_500KBPS, MCP_8MHZ);
  can_0.setNormalMode();

  pinMode(main_negative_contactor_relay, OUTPUT);
  pinMode(main_positive_contactor_relay, OUTPUT);
  pinMode(precharge_contactor_relay, OUTPUT);

  contactorStateRequestFrame.can_id = 0x100;
  contactorStateRequestFrame.can_dlc = 3;

  contactorStatusFrame.can_id = 0x101;
  contactorStatusFrame.can_dlc = 3;
}

void loop() {
  receive_frame();
  actuate_relays();
  send_status();
}

