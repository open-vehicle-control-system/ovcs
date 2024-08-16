#include <Controller.h>

void Controller::initializeSerial() {
  Serial.begin(115200);
  Serial.println(__FILE__);
  while (!Serial) {
    delay (50) ;
  }
};

void Controller::initializeI2C() {
  _mosfetBoard1->begin();
  _mosfetBoard2->begin();
};

bool Controller::isReady() {
  return _ready;
};

void Controller::adoptConfiguration() {
  _configuration.storeAndApply(_can._receivedFrame.data);
  _adoptionButton.validateAdoption();
};

void Controller::writeDigitalPins() {
  PinStatus* digitalPinsRequest = _can.parseDigitalPinRequest();
  for (uint8_t i = 0; i < 21; i++) {
    _configuration._digitalPins[i].writeIfAllowed(digitalPinsRequest[i]);
  }
};

void Controller::writeOtherPins() {
  OtherPinDutyCycles otherPinDutyCycles = _can.parseOtherPinRequest();
  for (uint8_t i = 0; i < 3; i++) {
    _configuration._pwmPins[i].writeIfAllowed(otherPinDutyCycles.pwmDutyCyles[i]);
  }
  _configuration._dacPin.writeIfAllowed(otherPinDutyCycles.dacDutyCycle);
};

uint8_t* Controller::readDigitalPins() {
  static uint8_t digitalPinsStatus[21]  = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  for (uint8_t i=0; i<21; i++) {
    digitalPinsStatus[i] = _configuration._digitalPins[i].readIfAllowed();
  }
  return digitalPinsStatus;
};

uint16_t* Controller::readAnalogPins() {
  static uint16_t analogPinsStatus [3]  = {0, 0, 0};
  for (uint8_t i=0; i<3; i++) {
    AnalogPin analogPin = _configuration._analogPins[i];
    analogPinsStatus[i] = analogPin.readIfAllowed();
  }
  return analogPinsStatus;
};

void Controller::emitPinStatuses() {
  uint8_t* digitalPinsStatus = readDigitalPins();
  uint16_t* analogPinsStatus = readAnalogPins();
  _can.emitdigitalAndAnalogPinsStatus(_configuration._digitalAndAnalogPinsStatusFrameId, digitalPinsStatus, analogPinsStatus);
};

void Controller::emitFrames() {
  emitPinStatuses();
  _can.emitAlive(_configuration._aliveFrameId);
};

void Controller::setup() {
  initializeSerial();
  _can.begin();
  initializeI2C();
  analogReadResolution(ANALOG_READ_RESOLUTION);
  analogWriteResolution(ANALOG_WRITE_RESOLUTION);
  if (_configuration.load()) {
    _ready = true;
  } else {
    _ready = false;
  }
};

void Controller::loop() {
  _can.receive();
  if (_adoptionButton.isWaitingAdoption() && _can._receivedFrame.id == ADOPTION_FRAME_ID) {
    Serial.println("--> Adoption started <--");
    adoptConfiguration();
  } else if (isReady()) {
    if (_can._receivedFrame.id == _configuration._digitalPinRequestFrameId) {
      writeDigitalPins();
    } else if (_can._receivedFrame.id == _configuration._otherPinRequestFrameId) {
      writeOtherPins();
    }
    emitFrames();
  }
};