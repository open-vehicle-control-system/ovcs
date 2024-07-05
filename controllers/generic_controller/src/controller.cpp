#include <controller.h>

void Controller::initializeSerial() {
  Serial.begin(115200);
  Serial.println(__FILE__);
  while (!Serial) {
    delay (50) ;
  }
};

void Controller::initializeI2C() {
  Wire.begin();
  MOSFETBoard1.begin();
  MOSFETBoard2.begin();
  Wire.setClock(I2C_CLOCK_FREQUENCY);
};

void Controller::setup() {
  initializeSerial();
  can.begin();
  initializeI2C();
  analogWriteResolution(12);
  if (configuration.load()) {
    ready = true;
  } else {
    ready = false;
  }
};

bool Controller::isReady() {
  return ready;
};

void Controller::adoptConfiguration() {
  configuration.storeAndApply(can.receivedFrame);
  adoptionButton.validateAdoption();
};

void Controller::setDigitalPins() {
  uint8_t pinNumber = 0;
  for(uint8_t byteNumber = 0; byteNumber < 3; byteNumber++) {
    for (uint8_t i = 1; i < 8; i++) {
      if (pinNumber < 21) {
        DigitalPin digitalPin = configuration.digitalPins[pinNumber];
        if (digitalPin.writeable()) {
          bool value = can.receivedFrame.data[byteNumber] >> 8 - i & 1;
          digitalPin.write(value);
        }
        pinNumber++;
      } else {
        i = 8;
      }
    }
  };
};

void Controller::setPwmPins() {
  uint16_t dutyCycle;
  PwmPin pwmPin;
  pwmPin = configuration.pwmPins[0];
  if (pwmPin.enabled) {
    dutyCycle = (can.receivedFrame.data[1] & 0b11110000) << 4 | can.receivedFrame.data[0];
    pwmPin.write(dutyCycle);
  }

  pwmPin = configuration.pwmPins[1];
  if (pwmPin.enabled) {
    dutyCycle =  (can.receivedFrame.data[2] & 0b00001111) << 8 | (can.receivedFrame.data[1] & 0b00001111) << 4 | (can.receivedFrame.data[2] & 0b11110000) >> 4  ;
    pwmPin.write(dutyCycle);
  }

  pwmPin = configuration.pwmPins[2];
  if (pwmPin.enabled) {
    dutyCycle = (can.receivedFrame.data[4] & 0b11110000) << 4 | can.receivedFrame.data[3];
    pwmPin.write(dutyCycle);
  }
};

void Controller::setDacPin() {
  uint16_t dutyCycle;
  DacPin dacPin = configuration.dacPin;

  if (dacPin.enabled) {
    dutyCycle =  (can.receivedFrame.data[5] & 0b00001111) << 8 | (can.receivedFrame.data[4] & 0b00001111) << 4 | (can.receivedFrame.data[5] & 0b11110000) >> 4  ;
    dacPin.write(dutyCycle);
  }
};

void Controller::emitPinStatuses() {
  // read Digital Pin based on configuration
  // read analog pins based on configuration
  // create can frame
  // send can frame
};

void Controller::loop() {
  can.receive();
  if (adoptionButton.isWaitingAdoption() && can.receivedFrame.id == ADOPTION_FRAME_ID) {
    Serial.println("--> Adoption started <--");
    adoptConfiguration();
  } else if (isReady()) {
    if (can.receivedFrame.id == configuration.digitalPinRequestFrameId) {
      setDigitalPins();
    } else if (can.receivedFrame.id == configuration.otherPinRequestFrameId) {
      setPwmPins();
      setDacPin();
    }
    emitPinStatuses();
    can.emitAlive(configuration.aliveFrameId);
  }
};