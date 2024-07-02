#include <main.h>
#include <configuration.h>

ACAN2517 can (MCP2517_CS, SPI, MCP2517_INT) ;

unsigned long pinStatusSendTimestamp = 0;
unsigned long now = 0;
Configuration configuration;
uint32_t digital_pin_request = 0;


bool waitingAdoption = false;
bool ready = false;
bool adoptedSinceLastBoot = false;

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

void initializeI2C() {
  Wire.begin();
  MOSFETBoard1.begin();
  MOSFETBoard2.begin();
  Wire.setClock(I2C_CLOCK_FREQUENCY);
}

void initializeCan() {
  SPI.begin ();
  ACAN2517Settings settings (ACAN2517Settings::OSC_40MHz, 500UL * 1000UL);
  settings.mDriverTransmitFIFOSize = 1;
  settings.mDriverReceiveFIFOSize  = 1;
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
    can.receive(receivedFrame);
  } else {
    receivedFrame = CANMessage();
  }
}

bool isWaitingAdoption() {
  if (adoptedSinceLastBoot) {
    return false;
  } else if (waitingAdoption) {
    return true;
  } else {
    waitingAdoption = digitalRead(ADOPTION_BUTTON_PIN) == HIGH;
    return waitingAdoption;
  }
}

void initializeAdoptionButton() {
  pinMode(ADOPTION_BUTTON_PIN, INPUT);
}

void storeConfiguration(CANMessage frame) {
  uint32_t crc = CRC32::calculate(frame.data, CONFIGURATION_BYTE_SIZE);
  EEPROM.put(CONFIGURATION_EEPROM_ADDRESS, frame.data);
  EEPROM.put(CONFIGURATION_CRC_EEPROM_ADDRESS, crc);
  adoptedSinceLastBoot = true;
}

void setDigitalPins(CANMessage receivedFrame) {
  uint8_t pinNumber = 0;
  for(uint8_t byteNumber = 0; byteNumber < 3; byteNumber++) {
    for (uint8_t i = 1; i < 8; i++) {
      if (pinNumber < 21) {
        DigitalPin digitalPin = configuration.digitalPins[pinNumber];
        if (digitalPin.writeable()) {
          bool value = receivedFrame.data[byteNumber] >> 8 - i & 1;
          digitalPin.write(value);
        }
        pinNumber++;
      } else {
        i = 8;
      }
    }
  };
}

void setOtherPins(CANMessage receivedFrame) {
  // Write other pin values based on writeable pins in config + other pin request in receivedFrame
}


void send_pin_status_frame() {
  CANMessage frame ;
  now = millis();
  if (pinStatusSendTimestamp + PIN_STATUS_FRAME_FREQUENCY_MS <= now) {
    pinStatusSendTimestamp = now;
    frame.id               = configuration.digitalAndAnalogPinStatusFrameId;
    frame.len              = 8;
    frame.data[0]          = 0xFF; // Fill with data
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
  uint32_t configurationCrc;
  uint8_t rawConfiguration [8];
  EEPROM.get(CONFIGURATION_EEPROM_ADDRESS, rawConfiguration);
  EEPROM.get(CONFIGURATION_CRC_EEPROM_ADDRESS, configurationCrc);
  crc = CRC32::calculate(rawConfiguration, CONFIGURATION_BYTE_SIZE);
  if (crc == configurationCrc) {
    configuration = Configuration(rawConfiguration);
    Serial.println("Saved configuration valid, ready!");
    ready = true;
  } else {
    ready = false;
    Serial.println("Saved configuration invalid, adoption required to continue.");
  }
}

void adoptConfiguration(CANMessage frame) {
  storeConfiguration(frame);
  loadConfiguration();
  waitingAdoption = false;
};

void setup()
{
  initializeSerial();
  initializeAdoptionButton();
  initializeCan();
  initializeI2C();
  loadConfiguration();

}

void loop () {
  receiveFrame();
  if (isWaitingAdoption() && receivedFrame.id == ADOPTION_FRAME_ID) {
    Serial.println("--> Adoption started <--");
    adoptConfiguration(receivedFrame);
  } else if (ready) {
    if (receivedFrame.id == configuration.digitalPinRequestFrameId) {
      setDigitalPins(receivedFrame);
    } else if (receivedFrame.id == configuration.otherPinRequestFrameId) {
      setOtherPins(receivedFrame);
    }
    sendPinStatuses();
  }
}