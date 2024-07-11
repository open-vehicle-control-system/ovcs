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

bool Controller::isReady() {
  return ready;
};

void Controller::adoptConfiguration() {
  configuration.storeAndApply(can.receivedFrame.data);
  adoptionButton.validateAdoption();
};

void Controller::writeDigitalPins() {
  bool* digitalPinsRequest = can.parseDigitalPinRequest();
  for (uint8_t i = 0; i < 21; i++) {
    configuration.digitalPins[i].writeIfAllowed(digitalPinsRequest[i]);
  }
};

void Controller::writeOtherPins() {
  OtherPinDutyCycles otherPinDutyCycles = can.parseOtherPinRequest();
  for (uint8_t i = 0; i < 3; i++) {
    configuration.pwmPins[i].writeIfAllowed(otherPinDutyCycles.pwmDutyCyles[i]);
  }
  configuration.dacPin.writeIfAllowed(otherPinDutyCycles.dacDutyCycle);
};

uint8_t* Controller::readDigitalPins() {
  static uint8_t digitalPinsStatus[21]  = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  for (uint8_t i=0; i<21; i++) {
    digitalPinsStatus[i] = configuration.digitalPins[i].readIfAllowed();
  }
  return digitalPinsStatus;
};

uint16_t* Controller::readAnalogPins() {
  static uint16_t analogPinsStatus [3]  = {0, 0, 0};
  for (uint8_t i=0; i<3; i++) {
    AnalogPin analogPin = configuration.analogPins[i];
    if (analogPin.readable()) {
      analogPinsStatus[i] = analogPin.read();
    }
  }
  return analogPinsStatus;
};

void Controller::emitPinStatuses() {
  uint8_t* digitalPinsStatus = readDigitalPins();
  uint16_t* analogPinsStatus = readAnalogPins();
  can.emitdigitalAndAnalogPinsStatus(configuration.digitalAndAnalogPinsStatusFrameId, digitalPinsStatus, analogPinsStatus);
};

void Controller::emitFrames() {
  emitPinStatuses();
  can.emitAlive(configuration.aliveFrameId);
};

void Controller::setup() {
  initializeSerial();
  can.begin();
  initializeI2C();
  analogReadResolution(ANALOG_READ_RESOLUTION);
  analogWriteResolution(ANALOG_WRITE_RESOLUTION);
  if (configuration.load()) {
    ready = true;
  } else {
    ready = false;
  }
};

void Controller::loop() {
  can.receive();
  if (adoptionButton.isWaitingAdoption() && can.receivedFrame.id == ADOPTION_FRAME_ID) {
    Serial.println("--> Adoption started <--");
    adoptConfiguration();
  } else if (isReady()) {
    if (can.receivedFrame.id == configuration.digitalPinRequestFrameId) {
      writeDigitalPins();
    } else if (can.receivedFrame.id == configuration.otherPinRequestFrameId) {
      writeOtherPins();
    }
    emitFrames();
  }
};