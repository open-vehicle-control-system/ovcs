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

void Controller::resetExpansionBoards() {
  Wire.end();
  initializeI2C();
  initializeExpansionBoards();
  _configuration.initializePhysicalPins();
};

void Controller::initializeI2C() {
  Wire.begin();
  Wire.setClock(I2C_CLOCK_FREQUENCY);
};

void Controller::initializeExpansionBoards() {
  if (_configuration._expansionBoard1InUse)  {
    _expansionBoard1->begin();
  }
  if (_configuration._expansionBoard2InUse)  {
    _expansionBoard2->begin();
  }
};

bool Controller::isReady() {
  return _status == READY;
};

void Controller::adoptConfiguration() {
  _configuration.storeAndApply(_can._receivedFrame.data);
  initializeExpansionBoards();
  _configuration.initializePhysicalPins();
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
    _configuration._pwmPins[i].writeIfAllowed(0);
  }
  _configuration._dacPin.writeIfAllowed(0);
};

void Controller::setExternalPwm() {
  ExternalPwm externalPwmRequest = _can.parseExternalPwmRequest();
  ExternalPwm& externalPwm = _configuration._externalPwms[externalPwmRequest.pwmId()];
  externalPwm.update(externalPwmRequest);
};

void Controller::disableExternalPwms() {
  for (uint8_t i = 0; i < 4; i++) {
    _configuration._externalPwms[i].disable();
  }
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
  unsigned long now = millis();
  if(_digitalAndAnalogPinStatusesTimestamp + DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS <= now){
    _digitalAndAnalogPinStatusesTimestamp = now;
    PinStatus* digitalPinsStatus = readDigitalPins();
    uint16_t* analogPinsStatus = readAnalogPins();
    _can.emitdigitalAndAnalogPinsStatus(_configuration._digitalAndAnalogPinsStatusFrameId, digitalPinsStatus, analogPinsStatus);
  }
};

void Controller::emitAlive(uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError) {
  unsigned long now = millis();
  if(_aliveEmittingTimestamp + ALIVE_FRAME_FREQUENCY_MS <= now){
    _aliveEmittingTimestamp = now;
    _can.emitAlive(_configuration._aliveFrameId, expansionBoard1LastError, expansionBoard2LastError, _status);
  }
};

void Controller::shutdown(ControllerStatus controllerStatus){
  _status = controllerStatus;
  shutdownAllDigitalPins();
  shutdownAllOtherPins();
  disableExternalPwms();
  DPRINT("Shutting down with error code: ");
  DPRINTLN(controllerStatus, HEX);
}

void Controller::watchVms() {
  unsigned long now = millis();
  bool booting_period_finished = now > VMS_ALLOWED_BOOT_TIME;
  if (booting_period_finished && _latestVmsAliveTimestamp + (VMS_ALIVE_MS + TOLERANCE_MS) * 4 < now){
    shutdown(VMS_MISSING_ERROR);
  } else if (_can._receivedFrame.id == VMS_ALIVE_FRAME_ID) {
    Vms vms = _can.parseVmsAliveFrame();
    if(_latestVmsAliveTimestamp + VMS_ALIVE_MS + TOLERANCE_MS > now){
      _vmsValidFramesWindow = min(VMS_VALID_FRAMES_WINDOW_SIZE, _vmsValidFramesWindow + 1);
    } else {
      _vmsValidFramesWindow = max(0, _vmsValidFramesWindow - 1);
    }
    uint8_t nextVmsAliveCounter = (_vmsAliveFrameCounter + 1) % 4;
    if(_vmsValidFramesWindow == 0) {
      shutdown(VMS_LATENCY_ERROR);
    } else if (vms.status == FAILURE) {
      shutdown(VMS_FAILURE_ERROR);
    } // else if (_vmsAliveFrameCounter != 255 && vms.counter != nextVmsAliveCounter) {
    //   shutdown(VMS_COUNTER_MISMATCH_ERROR);
    // }
    _vmsAliveFrameCounter = vms.counter;
  }
}

void Controller::watchExpansionBoards(uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError) {
  if(expansionBoard1LastError != 0 || expansionBoard2LastError != 0){
    shutdown(EXPANSION_BOARDS_ERROR);
  }
}

void Controller::handleVmsCommandFrame() {
  VmsCommand vmsCommand = _can.parseVmsCommandFrame();
  if (vmsCommand.command == RESET_GENERIC_CONTROLLERS) {
     _status = READY;
  }
};

uint8_t Controller::verifyExpansionBoardErrors(uint8_t boardId) {
  uint8_t lastError = 0;
  if (boardId == 1 && _configuration._expansionBoard1InUse) {
    lastError = _expansionBoard1->lastError();
  } else if (boardId == 2 && _configuration._expansionBoard2InUse) {
    lastError = _expansionBoard2->lastError();
  }
   unsigned long now = millis();
  if (lastError != 0) {
    _lastI2cErrorTimestamp = now;
    DPRINT("I2C Error for expansion board ");
    DPRINT(boardId);
    DPRINT(": ");
    DPRINTLN(lastError, HEX);
    if(_i2cRetryCount < MAX_I2C_RETRY){
      resetExpansionBoards();
      _i2cRetryCount += 1;
    } else {
      return lastError;
    }
  } else if (_lastI2cErrorTimestamp + ALLOWED_I2C_ERROR_TIMEFRAME < now ) {
    _i2cRetryCount = 0;
  }
  return 0;
};

void Controller::setup() {
  initializeSerial();
  initializeSerialTransfer();
  initializeI2C();
  _can.begin();
  analogReadResolution(ANALOG_READ_RESOLUTION);
  analogWriteResolution(ANALOG_WRITE_RESOLUTION);
  if (_configuration.load()) {
    initializeExpansionBoards();
    _configuration.initializePhysicalPins();
    _status = READY;
  } else {
    _status = ADOPTION_REQUIRED;
  }
};

void Controller::loop() {
  _can.receive();
  if (_can._receivedFrame.id == VMS_ALIVE_FRAME_ID) {
    _latestVmsAliveTimestamp = millis();
  }
  if (_adoptionButton.isWaitingAdoption()) {
    if (_status != ADOPTION_REQUIRED) {
      shutdown(ADOPTION_REQUIRED);
    }
    if (_can._receivedFrame.id == ADOPTION_FRAME_ID) {
      DPRINTLN("--> Adoption started <--");
      adoptConfiguration();
    }
  } else{
    uint8_t expansionBoard1LastError = verifyExpansionBoardErrors(1);
    uint8_t expansionBoard2LastError = verifyExpansionBoardErrors(2);
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
      };
      emitPinStatuses();
      watchVms();
      watchExpansionBoards(expansionBoard1LastError, expansionBoard2LastError);
    } else {
      if (_can._receivedFrame.id == VMS_COMMAND_FRAME_ID) {
        handleVmsCommandFrame();
      }
    };
    emitAlive(expansionBoard1LastError, expansionBoard2LastError);
  }
};