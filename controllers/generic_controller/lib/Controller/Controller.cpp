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
  if (_configuration._expansionBoard1InUse || _configuration._expansionBoard2InUse)  {
    Wire.end();
    Wire.begin();
    if (_configuration._expansionBoard1InUse)  {
      _expansionBoard1->begin();
    }
    if (_configuration._expansionBoard2InUse)  {
      _expansionBoard2->begin();
    }
    Wire.setClock(I2C_CLOCK_FREQUENCY);
  }
};

bool Controller::isReady() {
  return _status == READY;
};

void Controller::adoptConfiguration() {
  _configuration.storeAndApply(_can._receivedFrame.data);
  initializeI2C();
  _adoptionButton.validateAdoption();
};

void Controller::writeDigitalPins() {
  PinStatus* digitalPinsRequest = _can.parseDigitalPinRequest();
  for (uint8_t i = 0; i < 19; i++) {
    _configuration._digitalPins[i].writeIfAllowed(digitalPinsRequest[i]);
  }
};

void Controller::shutdownAllDigitalPins(){
  for (uint8_t i = 0; i < 19; i++) {
    _configuration._digitalPins[i].writeIfAllowed(LOW);
  }
};

void Controller::writeOtherPins() {
  OtherPinDutyCycles otherPinDutyCycles = _can.parseOtherPinRequest();
  for (uint8_t i = 0; i < 3; i++) {
    _configuration._pwmPins[i].writeIfAllowed(otherPinDutyCycles.pwmDutyCyles[i]);
  }
  _configuration._dacPin.writeIfAllowed(otherPinDutyCycles.dacDutyCycle);
};

void Controller::shutdownAllOtherPins(){
  for (uint8_t i = 0; i < 3; i++) {
    _configuration._pwmPins[i].writeIfAllowed(LOW);
  }
  _configuration._dacPin.writeIfAllowed(LOW);
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

void Controller::emitFrames(uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError) {
  unsigned long now = millis();
  if(_digitalAndAnalogPinStatusesTimestamp + DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS <= now){
    _digitalAndAnalogPinStatusesTimestamp = now;
    emitPinStatuses();
  }

  if(_aliveEmittingTimestamp + ALIVE_FRAME_FREQUENCY_MS <= now){
    _aliveEmittingTimestamp = now;
    _can.emitAlive(_configuration._aliveFrameId, expansionBoard1LastError, expansionBoard2LastError, _status);
  }
};

void Controller::watchVms() {
  unsigned long now = millis();
  if(_can._receivedFrame.id == _configuration._vmsAliveFrameId){
    _latestVmsAliveTimestamp = now;

    if(_latestVmsAliveTimestamp + VMS_ALIVE_MS < now){
      _vmsValidFramesWindow = max(0, _vmsValidFramesWindow - 1);
    } else {
      _vmsValidFramesWindow = min(VMS_VALID_FRAMES_WINDOW_SIZE, _vmsValidFramesWindow + 1);
    }

    if(_vmsValidFramesWindow == 0){
      _status = FAILSAFE;
      shutdownAllDigitalPins();
      shutdownAllOtherPins();
    } else {
      _status = READY;
    }
  }
}

void Controller::setup() {

  initializeSerial();
  initializeSerialTransfer();
  _can.begin();
  analogReadResolution(ANALOG_READ_RESOLUTION);
  analogWriteResolution(ANALOG_WRITE_RESOLUTION);
  if (_configuration.load()) {
    initializeI2C();
    _status = READY;
  } else {
    _status = ADOPTION_REQUIRED;
  }
};

uint8_t Controller::verifyExpansionBoardErrors(uint8_t boardId) {
  uint8_t lastError = 0;
  if (boardId == 1 && _configuration._expansionBoard1InUse) {
    lastError = _expansionBoard1->lastError();
  } else if (boardId == 2 && _configuration._expansionBoard2InUse) {
    lastError = _expansionBoard2->lastError();
  }
  if (lastError != 0 ) {
    DPRINT("I2C Error for expansion board");
    DPRINT(boardId);
    DPRINT(": ");
    DPRINTLN(lastError, HEX);
    initializeI2C();
  }
  return lastError;
};

void Controller::loop() {
  _can.receive();
  if (_adoptionButton.isWaitingAdoption() && _can._receivedFrame.id == ADOPTION_FRAME_ID) {
    DPRINTLN("--> Adoption started <--");
    adoptConfiguration();
  } else{
    if (isReady()) {
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
    };
    uint8_t expansionBoard1LastError = verifyExpansionBoardErrors(1);
    uint8_t expansionBoard2LastError = verifyExpansionBoardErrors(2);
    emitFrames(expansionBoard1LastError, expansionBoard2LastError);
    watchVms();
  }
};