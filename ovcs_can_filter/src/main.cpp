#include <SPI.h>
#include <mcp2515.h>
#include <ArduinoJson.h>

struct can_frame receivedCanMessage;
MCP2515 can_0(10);
MCP2515 can_1(9);
struct can_frame sentCanMessage;
JsonDocument mapping;
 const char* json = "{\"0x570\": {\"name\": \"keyState\", \"mappedId\": 1, \"mappedLength\": 1, \"mappedStart\":0, \"mappedValues\": {\"0x0\":0,\"0x1\":1,\"0x87\":2,\"0x8B\":3}}}}";

void setup() {
  Serial.begin(9600);

  DeserializationError error = deserializeJson(mapping, json);

  // Test if parsing succeeds.
  if (error) {
    Serial.print(F("deserializeJson() failed: "));
    Serial.println(error.f_str());
    return;
  }

  can_0.reset();
  can_0.setBitrate(CAN_500KBPS, MCP_8MHZ);
  can_0.setNormalMode();

  can_1.reset();
  can_1.setBitrate(CAN_1000KBPS, MCP_8MHZ);
  can_1.setNormalMode();
}

void loop() {
  if (can_0.readMessage(&receivedCanMessage) == MCP2515::ERROR_OK) {
    JsonDocument mapped = mapping[String(receivedCanMessage.can_id, HEX)];
    if (mapped.isNull()) {
      Serial.print("CAN0: " + mapped["name"]); 
      Serial.println();
      int value = receivedCanMessage.data[mapped["mappedStart"]];
      sentCanMessage.can_id  = mapped["mappedId"];
      sentCanMessage.can_dlc = mapped["mappedLength"];
      sentCanMessage.data[0] = mapped["mappedValues"][String(receivedCanMessage.can_id, HEX)];
      can_1.sendMessage(&sentCanMessage);      
    }  
  } 
}