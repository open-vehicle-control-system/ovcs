#include <SPI.h>
#include <mcp2515.h>
#include <EEPROM.h>

#define THROTTLE_PEDAL_PIN A0
#define THROTTLE_CAN_MESSAGE_FREQUENCY_MS 10

unsigned long sendingTimestamp = 0;
unsigned long now;

struct can_frame receivedCanMessage;
struct can_frame throttleCanMessage;
MCP2515 can_0(10);

int calibration_mode = false;
int was_in_calibration_mode = false;

int throttle_pedal_calibration_low = 1023;
int throttle_pedal_calibration_high = 0;

void send_can_message(int value){
  now = millis();
  if(sendingTimestamp + THROTTLE_CAN_MESSAGE_FREQUENCY_MS <= now){
    sendingTimestamp = now;
    int throttle = ((value - throttle_pedal_calibration_low)/4*255) / ((throttle_pedal_calibration_high - throttle_pedal_calibration_low)/4);
    throttleCanMessage.can_id = 0x200;
    throttleCanMessage.can_dlc = 1;
    throttleCanMessage.data[0] = throttle;
    can_0.sendMessage(&throttleCanMessage);
  }
}

void read_values_from_eeprom(){
  int eeprom_throttle_pedal_low = EEPROM.read(0)*4;
  throttle_pedal_calibration_low = eeprom_throttle_pedal_low;
  int eeprom_throttle_pedal_high = EEPROM.read(1)*4;
  throttle_pedal_calibration_high = eeprom_throttle_pedal_high;
}

void save_values_to_eeprom(){
  // Divide by 4 as max value for analog is 1023 but bytes
  // in EEPROM can hold value up to 255
  EEPROM.write(0, throttle_pedal_calibration_low/4);
  Serial.print("Eeprom throttle low: ");
  Serial.println(throttle_pedal_calibration_low/4);
  EEPROM.write(1, throttle_pedal_calibration_high/4);
  Serial.print("Eeprom throttle high: ");
  Serial.println(throttle_pedal_calibration_high/4);
}

void listen_to_canbus() {
  if (can_0.readMessage(&receivedCanMessage) == MCP2515::ERROR_OK) {
    if(receivedCanMessage.can_id == 0x500 && receivedCanMessage.data[0] == 1){
      calibration_mode = true;
      if(was_in_calibration_mode == false){
        was_in_calibration_mode = true;
      }
      Serial.println("System is now in calibration mode");
    }
    if(receivedCanMessage.can_id == 0x500 && receivedCanMessage.data[0] == 0){
      calibration_mode = false;
      if(was_in_calibration_mode == true){
        Serial.println("Was in calibration mode, saving values to EEPROM...");
        save_values_to_eeprom();
        was_in_calibration_mode = false;
      }
    }
  }
}

void setup() {
  Serial.begin(9600);

  can_0.reset();
  can_0.setBitrate(CAN_500KBPS, MCP_8MHZ);
  can_0.setNormalMode();

  read_values_from_eeprom();
}

void loop() {
  listen_to_canbus();
  if(calibration_mode){
    int throttle_pedal_resistance = analogRead(THROTTLE_PEDAL_PIN);
    throttle_pedal_calibration_low = min(throttle_pedal_resistance, throttle_pedal_calibration_low);
    throttle_pedal_calibration_high = max(throttle_pedal_resistance, throttle_pedal_calibration_high);
  } else {
    was_in_calibration_mode = false;
    int throttle_pedal_resistance = analogRead(THROTTLE_PEDAL_PIN);
    send_can_message(throttle_pedal_resistance);
  }
}