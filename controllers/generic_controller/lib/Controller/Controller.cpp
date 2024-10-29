#include <Controller.h>

void Controller::initializeSerial() {
  #if DEBUG
    Serial.begin(115200);
    Serial.println(__FILE__);
    while (!Serial) {
      delay (50) ;
    }
  #endif
}
void Controller::initializeSerialTransfer() {
  Serial1.begin(115200);
  _serialTransfer->begin(Serial1);
};

void Controller::initializeI2C() {
  Wire.begin();
  _expansionBoard1->begin();
  _expansionBoard2->begin();
  Wire.setClock(I2C_CLOCK_FREQUENCY);
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
  for (uint8_t i = 0; i < 19; i++) {
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

void Controller::setExternalPwm() {
  ExternalPwm externalPwmRequest = _can.parseExternalPwmRequest();
  ExternalPwm& externalPwm = _configuration._externalPwms[externalPwmRequest.pwmId()];
  externalPwm.update(externalPwmRequest);
};

PinStatus* Controller::readDigitalPins() {
  static PinStatus digitalPinsStatus[19]  = {LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW};
  for (uint8_t i=0; i < 19; i++) {
    digitalPinsStatus[i] = _configuration._digitalPins[i].readIfAllowed();
  }
  return digitalPinsStatus;
};

uint16_t* Controller::readAnalogPins() {
  static uint16_t analogPinsStatus [3]  = {0, 0, 0};
  for (uint8_t i=0; i<3; i++) {
    AnalogPin& analogPin = _configuration._analogPins[i];
    analogPinsStatus[i] = analogPin.readIfAllowed();
  }
  return analogPinsStatus;
};

void Controller::emitPinStatuses() {
  PinStatus* digitalPinsStatus = readDigitalPins();
  uint16_t* analogPinsStatus = readAnalogPins();
  _can.emitdigitalAndAnalogPinsStatus(_configuration._digitalAndAnalogPinsStatusFrameId, digitalPinsStatus, analogPinsStatus);
};

void Controller::emitFrames() {
  emitPinStatuses();
  _can.emitAlive(_configuration._aliveFrameId);
};

void Controller::setup() {
  initializeSerial();
  initializeSerialTransfer();
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
    DPRINTLN("--> Adoption started <--");
    adoptConfiguration();
  } else if (isReady()) {
    if (_can._receivedFrame.id == _configuration._digitalPinRequestFrameId) {
      writeDigitalPins();
    } else if (_can._receivedFrame.id == _configuration._otherPinRequestFrameId) {
      writeOtherPins();
    } else if (
        _can._receivedFrame.id == _configuration._externalPwm0RequestFrameId ||
        _can._receivedFrame.id == _configuration._externalPwm1RequestFrameId ||
        _can._receivedFrame.id == _configuration._externalPwm2RequestFrameId ||
        _can._receivedFrame.id == _configuration._externalPwm3RequestFrameId) {
      setExternalPwm();
    }
    emitFrames();
  }
};