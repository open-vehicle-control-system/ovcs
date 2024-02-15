#include <TransportUtils.h>

#include <SPI.h>
#include <mcp2515.h>

#define THROTTLE_CAN_MESSAGE_FREQUENCY_MS 10
#define THROTTLE_CAN_MESSAGE_ID 0x200
#define CAN_PIN 10
#define CAN_SPEED CAN_500KBPS
#define CAN_FREQUENCY MCP_8MHZ
#define GEAR_CAN_MESSAGE_ID 0x600

unsigned long sendingTimestamp = 0;
unsigned long now;

can_frame sentCanMessage;
can_frame receivedCanMessage;

MCP2515 OVCS_CAN(CAN_PIN);

boolean initialize_transport(){
  OVCS_CAN.reset();
  OVCS_CAN.setBitrate(CAN_SPEED, CAN_FREQUENCY);
  OVCS_CAN.setNormalMode();
  return OVCS_CAN.checkError();
}

void send_message(int max_analog_read_value, int value_voltage_1, int value_voltage_2, int selected_gear){
  now = millis();
  if(sendingTimestamp + THROTTLE_CAN_MESSAGE_FREQUENCY_MS <= now){
    sendingTimestamp = now;
    sentCanMessage.can_id = THROTTLE_CAN_MESSAGE_ID;
    sentCanMessage.can_dlc = 7;
    sentCanMessage.data[0] = lowByte(max_analog_read_value);
    sentCanMessage.data[1] = highByte(max_analog_read_value);
    sentCanMessage.data[2] = lowByte(value_voltage_1);
    sentCanMessage.data[3] = highByte(value_voltage_1);
    sentCanMessage.data[4] = lowByte(value_voltage_2);
    sentCanMessage.data[5] = highByte(value_voltage_2);
    sentCanMessage.data[6] = selected_gear;
    OVCS_CAN.sendMessage(&sentCanMessage);
  }
}

int receive_validated_gear(){
  if(OVCS_CAN.readMessage(&receivedCanMessage) == MCP2515::ERROR_OK){
    if(receivedCanMessage.can_id == GEAR_CAN_MESSAGE_ID){
      return receivedCanMessage.data[0];
    }
    else{
      return -1;
    }
  }
}
