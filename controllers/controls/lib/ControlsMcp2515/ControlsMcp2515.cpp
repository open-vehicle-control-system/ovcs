#include <Arduino.h>
#include <SPI.h>
#include <mcp2515.h>
#include <ControlsMcp2515.h>

#define KEEP_ALIVE_CAN_MESSAGE_FREQUENCY_MS 10
#define KEEP_ALIVE_CAN_MESSAGE_ID 0x300
#define THROTTLE_CAN_MESSAGE_FREQUENCY_MS 10
#define THROTTLE_CAN_MESSAGE_ID 0x200
#define CAN_PIN 10
#define CAN_SPEED CAN_500KBPS
#define CAN_FREQUENCY MCP_8MHZ
#define GEAR_CAN_MESSAGE_ID 0x600

unsigned long throttleSendingTimestamp = 0;
unsigned long keepEliveSendingTimestamp = 0;

unsigned long now;

can_frame sentCanMessage;
can_frame receivedCanMessage;

MCP2515 OVCS_CAN(CAN_PIN);

boolean ControlsMcp2515::initialize(){
  OVCS_CAN.reset();
  OVCS_CAN.setBitrate(CAN_SPEED, CAN_FREQUENCY);
  OVCS_CAN.setNormalMode();
  return !OVCS_CAN.checkError();
}

void ControlsMcp2515::sendFrame(int maxAnalogReadValue, int throttleValue1, int throttleValue2, int selectedGear){
  now = millis();
  if(throttleSendingTimestamp + THROTTLE_CAN_MESSAGE_FREQUENCY_MS <= now){
    throttleSendingTimestamp = now;
    sentCanMessage.can_id = THROTTLE_CAN_MESSAGE_ID;
    sentCanMessage.can_dlc = 7;
    sentCanMessage.data[0] = lowByte(maxAnalogReadValue);
    sentCanMessage.data[1] = highByte(maxAnalogReadValue);
    sentCanMessage.data[2] = lowByte(throttleValue1);
    sentCanMessage.data[3] = highByte(throttleValue1);
    sentCanMessage.data[4] = lowByte(throttleValue2);
    sentCanMessage.data[5] = highByte(throttleValue2);
    sentCanMessage.data[6] = selectedGear;
    OVCS_CAN.sendMessage(&sentCanMessage);
  }
}

void ControlsMcp2515::sendKeepAlive(int status){
  now = millis();
  if(keepEliveSendingTimestamp + KEEP_ALIVE_CAN_MESSAGE_FREQUENCY_MS <= now){
    keepEliveSendingTimestamp = now;
    sentCanMessage.can_id = KEEP_ALIVE_CAN_MESSAGE_ID;
    sentCanMessage.can_dlc = 1;
    sentCanMessage.data[0] = status;
    OVCS_CAN.sendMessage(&sentCanMessage);
  }
}

int ControlsMcp2515::pullValidatedGear(){
  if(OVCS_CAN.readMessage(&receivedCanMessage) == MCP2515::ERROR_OK){
    if(receivedCanMessage.can_id == GEAR_CAN_MESSAGE_ID){
      return receivedCanMessage.data[0];
    }
    else{
      return -1;
    }
  }
}
