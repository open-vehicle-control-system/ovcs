#include <CanUtils.h>

#define THROTTLE_CAN_MESSAGE_FREQUENCY_MS 10

unsigned long sendingTimestamp = 0;
unsigned long now;

can_frame sentCanMessage;
can_frame receivedCanMessage;

boolean initialize_can(MCP2515 canbus){
  canbus.reset();
  canbus.setBitrate(CAN_1000KBPS, MCP_8MHZ);
  canbus.setNormalMode();
  return canbus.checkError();
}

void send_throttle_message(MCP2515 canbus, int value){
  now = millis();
  if(sendingTimestamp + THROTTLE_CAN_MESSAGE_FREQUENCY_MS <= now){
    sendingTimestamp = now;
    sentCanMessage.can_id = 0x200;
    sentCanMessage.can_dlc = 1;
    sentCanMessage.data[0] = value;
    canbus.sendMessage(&sentCanMessage);
  }
}

struct can_frame read_can_message(MCP2515 canbus, int id){
  if(canbus.readMessage(&receivedCanMessage) == MCP2515::ERROR_OK){
    if(receivedCanMessage.can_id == id){
      return receivedCanMessage;
    }
  }
}
