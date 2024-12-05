#include <Can.h>
#include <Controller.h>

void Can::begin() {
  SPI.begin ();
  ACAN2517Settings settings (CAN_OSCILLATOR, CAN_BITRATE);
  settings.mDriverTransmitFIFOSize = 1;
  settings.mDriverReceiveFIFOSize  = 1;

  const uint32_t errorCode = acan.begin (settings, [] { acan.isr () ; });
  if (errorCode == 0) {
    DPRINTLN("> CAN Ready");
  } else {
    DPRINT("> CAN Configuration error 0x");
    DPRINTLN(errorCode, HEX);
  }
};

void Can::receive() {
  if (acan.available()) {
    acan.receive(_receivedFrame);
  } else {
    _receivedFrame.id = 0;
  }
};

void Can::emit(CANMessage frame) {
  const bool ok = acan.tryToSend (frame) ;
  if (!ok) {
    DPRINTLN("CAN emit failure") ;
  }
};

void Can::emitAlive(uint16_t aliveFrameId, uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError, ControllerStatus status) {
  CANMessage frame;
  frame.id      = aliveFrameId;
  frame.len     = 4;
  frame.data[0] = _aliveCounter;
  frame.data[1] = (uint8_t)status;
  frame.data[2] = expansionBoard1LastError;
  frame.data[3] = expansionBoard2LastError;
  _aliveCounter = (_aliveCounter + 1) % 3;
  emit(frame);
};

void Can::emitdigitalAndAnalogPinsStatus(uint16_t digitalAndAnalogPinStatusesFrameId, PinStatus digitalPinsStatus [19], uint16_t analogPinsStatus [3]) {
  CANMessage frame;
  frame.id  = digitalAndAnalogPinStatusesFrameId;
  frame.len = 8;

  for(uint8_t i = 0; i < 19; i++) {
    uint8_t byteNumber = i / 8;
    uint8_t bitNumber  = 7 - (i % 8);
    bitWrite(frame.data[byteNumber], bitNumber, digitalPinsStatus[i] == HIGH ? 1 : 0);
  }

  frame.data[2] = frame.data[2]                                              | extractBits(analogPinsStatus[0], 0b00000011111000, 3);
  frame.data[3] = extractBits(analogPinsStatus[0], 0b00000000000111, 0) << 5 | extractBits(analogPinsStatus[0], 0b11111000000000, 9);
  frame.data[4] = extractBits(analogPinsStatus[0], 0b00000100000000, 8) << 7 | extractBits(analogPinsStatus[1], 0b00000011111110, 1);
  frame.data[5] = extractBits(analogPinsStatus[1], 0b00000000000001, 0) << 7 | extractBits(analogPinsStatus[1], 0b11111100000000, 8);
  frame.data[6] = extractBits(analogPinsStatus[2], 0b00000011111111, 0);
  frame.data[7] = extractBits(analogPinsStatus[2], 0b11111100000000, 8) << 2;

  emit(frame);
};


PinStatus* Can::parseDigitalPinRequest() {
  static PinStatus digitalPinRequest[19] = {LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW, LOW};
  uint8_t pinNumber = 0;
  for(uint8_t i = 0; i < 19; i++) {
    uint8_t byteNumber   = i / 8;
    uint8_t bitNumber    = 7 - (i % 8);
    digitalPinRequest[i] = bitRead(_receivedFrame.data[byteNumber], bitNumber) == 0 ? LOW : HIGH;
  }

  return digitalPinRequest;
};

OtherPinDutyCycles Can::parseOtherPinRequest() {
  OtherPinDutyCycles otherPinDutyCycles;

  otherPinDutyCycles.pwmDutyCyles[0] = extractBits(_receivedFrame.data[1], 0b11110000, 4) << 8 | _receivedFrame.data[0];
  otherPinDutyCycles.pwmDutyCyles[1] = extractBits(_receivedFrame.data[2], 0b00001111, 0) << 8 | extractBits(_receivedFrame.data[1], 0b00001111, 0) << 4 |  extractBits(_receivedFrame.data[2], 0b11110000, 4);
  otherPinDutyCycles.pwmDutyCyles[2] = extractBits(_receivedFrame.data[4], 0b11110000, 4) << 4 | _receivedFrame.data[3];
  otherPinDutyCycles.dacDutyCycle    = extractBits(_receivedFrame.data[5], 0b00001111, 0) << 8 | extractBits(_receivedFrame.data[4], 0b00001111, 0) << 4 |  extractBits(_receivedFrame.data[5], 0b11110000, 4);

  return otherPinDutyCycles;
};

ExternalPwm Can::parseExternalPwmRequest() {
  uint8_t  pwmId     = (_receivedFrame.id & 0b1111) - 5;
  bool     enabled   = _receivedFrame.data[0];
  uint16_t dutyCycle = _receivedFrame.data[2] << 8 | _receivedFrame.data[1];
  uint16_t frequency = _receivedFrame.data[4] << 8 | _receivedFrame.data[3];
  return ExternalPwm(pwmId, enabled, dutyCycle, frequency);
};

Vms Can::parseVmsAliveFrame() {
  Vms vms;
  vms.status       = (VmsStatus)_receivedFrame.data[0];
  vms.readyToDrive = _receivedFrame.data[1];
  vms.counter      = _receivedFrame.data[2];

  return vms;
};

VmsCommand Can::parseVmsCommandFrame() {
  VmsCommand vmsCommand;
  vmsCommand.command = (Command)_receivedFrame.data[0];
  return vmsCommand;
};

uint8_t Can::extractBits(uint16_t source, uint16_t mask, uint8_t shiftRight) {
  return (source & mask) >> shiftRight;
};