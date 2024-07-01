#include <Arduino.h>
#include "MCP23008.h"
#include <ACAN2517.h>
#include <SPI.h>
#include <EEPROM.h>
#include <CRC32.h>

#define ON 1
#define OFF 0
#define OUTPUT_PIN_MODE 0x00
#define I2C_CLOCK_FREQUENCY 100000
#define PIN_STATUS_FRAME_FREQUENCY_MS 10
#define ADOPTION_BUTTON_PIN 2
#define ADOPTION_FRAME_ID 0x700
#define CONTROLLER_ID_EEPROM_ADDRESS 0
#define CONTROLLER_ID_CRC_EEPROM_ADDRESS 16
#define DIGITAL_PIN_CONFIGURATION_EEPROM_ADDRESS 48
#define DIGITAL_PIN_CONFIGURATION_CRC_EEPROM_ADDRESS 112
#define OTHER_PIN_CONFIGURATION_EEPROM_ADDRESS 144
#define OTHER_PIN_CONFIGURATION_CRC_EEPROM_ADDRESS 152
#define ALIVE_FRAME_ID_MASK 0x700
#define DIGITAL_PIN_REQUEST_FRAME_ID_MASK 0x701
#define OTHER_PIN_REQUEST_FRAME_ID_MASK 0x702
#define DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK 0x703

MCP23008 I2C_MOSFET_1(0x27);
MCP23008 I2C_MOSFET_2(0x26);

static const byte MCP2517_CS  = 10;
static const byte MCP2517_INT = 3;

ACAN2517 can (MCP2517_CS, SPI, MCP2517_INT) ;

unsigned long pinStatusSendTimestamp = 0;
unsigned long now = 0;
uint16_t controllerId;
uint64_t digitalPinConfiguration;
uint8_t  otherPinConfiguration;
uint32_t digital_pin_request = 0;

uint16_t aliveFrameId;
uint16_t digitalPinRequestFrameId;
uint16_t otherPinRequestFrameId;
uint16_t digitalAndAnalogPinStatusFrameId;

bool waitingAdoption = false;
bool ready = false;

CANMessage receivedFrame;

void can_send(CANMessage frame) {
  const bool ok = can.tryToSend (frame) ;
  if (!ok) {
    Serial.println ("Send failure") ;
  }
}

void initializeSerial() {
  Serial.begin(115200);
  Serial.println(__FILE__);
  while (!Serial) {
    delay (50) ;
  }
}

void initializeMosfetBoard(MCP23008 mosfet) {
  mosfet.begin();
  mosfet.pinMode8(OUTPUT_PIN_MODE);
  mosfet.write8(0x00);
};

void initializeMosfetBoards() {
  Wire.begin();
  initializeMosfetBoard(I2C_MOSFET_1);
  initializeMosfetBoard(I2C_MOSFET_2);
  Wire.setClock(I2C_CLOCK_FREQUENCY);
}

void initializeCan() {
  SPI.begin ();
  ACAN2517Settings settings (ACAN2517Settings::OSC_40MHz, 500UL * 1000UL);
  settings.mDriverTransmitFIFOSize = 1;
  settings.mDriverReceiveFIFOSize = 1;
  const uint32_t errorCode = can.begin (settings, [] { can.isr () ; });
  if (errorCode == 0) {
    Serial.println("CAN Ready");
  } else {
    Serial.print ("Configuration error 0x");
    Serial.println (errorCode, HEX);
  }
}

void receiveFrame() {
  if (can.available()) {
    can.receive(receivedFrame) ;
  }
}

bool isWaitingAdoption() {
  if (waitingAdoption) {
    return true;
  } else {
    waitingAdoption = digitalRead(ADOPTION_BUTTON_PIN) == HIGH;
    return waitingAdoption;
  }
}

void initializeAdoptionButton() {
  pinMode(ADOPTION_BUTTON_PIN, INPUT);
}

void storeId(CANMessage frame) {
  // Store Id + CRC on EEPROM
}
void storeDigitalPinConfiguration(CANMessage frame) {
  // Store digital Pin config + CRC on EEPROM
}
void storeOtherPinConfiguration(CANMessage frame) {
  // Store other PIN + CRC on EEPROM
}

void setDigitalPins(CANMessage receivedFrame) {
  // Write digital pin values based on writeable pins in config + digital pin request in receivedFrame
}

void setOtherPins(CANMessage receivedFrame) {
  // Write other pin values based on writeable pins in config + other pin request in receivedFrame
}


void send_pin_status_frame() {
  CANMessage frame ;
  now = millis();
  if (pinStatusSendTimestamp + PIN_STATUS_FRAME_FREQUENCY_MS <= now) {
    pinStatusSendTimestamp = now;
    frame.id = digitalAndAnalogPinStatusFrameId;
    frame.len = 8;
    frame.data[0] = 0xFF; // Fill with data
   can_send(frame);
  }
}

void sendPinStatuses() {
  // read Digital Pin based on configuration
  // read analog pins based on configuration
  // create can frame
  // send can frame
}

uint16_t computeFrameId(uint8_t controllerId, uint16_t mask) {
  uint16_t shiftedId = controllerId << 3;
  return shiftedId | mask;
}
void loadConfiguration() {
  uint32_t crc;
  // Controller ID
  bool controllerIdValid = false;
  uint32_t controllerIdCrc;
  size_t controllerIdByteSize = 2;
  EEPROM.get(CONTROLLER_ID_EEPROM_ADDRESS, controllerId);
  EEPROM.get(CONTROLLER_ID_CRC_EEPROM_ADDRESS, controllerIdCrc);
  crc = CRC32::calculate(&controllerId, controllerIdByteSize);
  if (crc == controllerIdCrc) {
    controllerIdValid = true;
  }
  // Digital Pin Configuration
  bool digitalPinConfigurationValid = false;
  uint32_t digitalPinConfigurationCrc;
  size_t digitalPinConfigurationSize = 8;
  EEPROM.get(DIGITAL_PIN_CONFIGURATION_EEPROM_ADDRESS, digitalPinConfiguration);
  EEPROM.get(DIGITAL_PIN_CONFIGURATION_CRC_EEPROM_ADDRESS, digitalPinConfigurationCrc);
  crc = CRC32::calculate(&controllerId, digitalPinConfigurationSize);
  if (crc == digitalPinConfigurationCrc) {
    digitalPinConfigurationValid = true;
  }

  // Other Pin Configuration
  bool otherPinConfigurationValid = false;
  uint32_t otherPinConfigurationCrc;
  size_t otherPinConfigurationByteSize = 8;
  EEPROM.get(DIGITAL_PIN_CONFIGURATION_EEPROM_ADDRESS, otherPinConfiguration);
  EEPROM.get(DIGITAL_PIN_CONFIGURATION_CRC_EEPROM_ADDRESS, otherPinConfigurationCrc);
  crc = CRC32::calculate(&controllerId, otherPinConfigurationByteSize);
  if (crc == otherPinConfigurationCrc) {
    otherPinConfigurationValid = true;
  }

  if (controllerIdValid && digitalPinConfigurationValid && otherPinConfigurationValid) {
    Serial.println("Saved configuration loaded, ready!");
    aliveFrameId                     = computeFrameId(controllerId, ALIVE_FRAME_ID_MASK);
    digitalPinRequestFrameId         = computeFrameId(controllerId, DIGITAL_PIN_REQUEST_FRAME_ID_MASK);
    otherPinRequestFrameId           = computeFrameId(controllerId, OTHER_PIN_REQUEST_FRAME_ID_MASK);
    digitalAndAnalogPinStatusFrameId = computeFrameId(controllerId, DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK);
    ready                            = true;
  } else {
    Serial.println("Saved configuration invalid, adoption required to continue.");
  }
}

void adoptConfiguration(CANMessage frame) {
  storeId(frame);
  storeDigitalPinConfiguration(frame);
  storeOtherPinConfiguration(frame);
  loadConfiguration();
  waitingAdoption = false;
};

void setup()
{
  initializeSerial();
  initializeAdoptionButton();
  initializeCan();
  initializeMosfetBoards();
  loadConfiguration();
}

void loop () {
  receiveFrame();
  if (isWaitingAdoption() && receivedFrame.id == ADOPTION_FRAME_ID) {
    Serial.println("Adoption started");
    adoptConfiguration(receivedFrame);
  } else if (ready) {
    if (receivedFrame.id == digitalPinRequestFrameId) {
      setDigitalPins(receivedFrame);
    } else if (receivedFrame.id == otherPinRequestFrameId) {
      setOtherPins(receivedFrame);
    }
    sendPinStatuses();
  }
}
