#include <SPI.h>
#include <mcp2515.h>

struct can_frame receivedCanMessage;
MCP2515 can_0(10);
MCP2515 can_1(9);
struct can_frame sentCanMessage;

void setup() {
  Serial.begin(9600);
  
  can_0.reset();
  can_0.setBitrate(CAN_500KBPS, MCP_8MHZ);
  can_0.setNormalMode();

  can_1.reset();
  can_1.setBitrate(CAN_500KBPS, MCP_8MHZ);
  can_1.setNormalMode();
  
  Serial.println("------- CAN Read ----------");
  Serial.println("ID  DLC   DATA");
}

void loop() {
  if (can_0.readMessage(&receivedCanMessage) == MCP2515::ERROR_OK) {
    if (receivedCanMessage.can_id == 0x570) {
      Serial.print("CAN0: ");
      Serial.print(receivedCanMessage.can_id, HEX); // print ID
      for (int i = 0; i<receivedCanMessage.can_dlc; i++)  {  // print the data
        Serial.print(receivedCanMessage.data[i],HEX);
        Serial.print(" ");
      }
      Serial.println();
      sentCanMessage.can_id  = 0x0F6;
      sentCanMessage.can_dlc = 8;
      sentCanMessage.data[0] = 0x8E;
      sentCanMessage.data[1] = 0x87;
      sentCanMessage.data[2] = 0x32;
      sentCanMessage.data[3] = 0xFA;
      sentCanMessage.data[4] = 0x26;
      sentCanMessage.data[5] = 0x8E;
      sentCanMessage.data[6] = 0xBE;
      sentCanMessage.data[7] = 0x86;
      can_1.sendMessage(&sentCanMessage);      
    }  
  } 
}