#include <can.h>
#include <controller.h>

void Can::begin() {
  SPI.begin ();
  ACAN2517Settings settings (CAN_OSCILLATOR, CAN_BITRATE);
  settings.mDriverTransmitFIFOSize = 1;
  settings.mDriverReceiveFIFOSize  = 1;

  const uint32_t errorCode = acan.begin (settings, [] { acan.isr () ; });
  if (errorCode == 0) {
    Serial.println("> CAN Ready");
  } else {
    Serial.print ("> CAN Configuration error 0x");
    Serial.println (errorCode, HEX);
  }
};

void Can::receive() {
  if (acan.available()) {
    acan.receive(receivedFrame);
  } else {
    receivedFrame.id = 0;
  }
};

void Can::emit(CANMessage frame) {
  const bool ok = acan.tryToSend (frame) ;
  if (!ok) {
    Serial.println ("CAN emit failure") ;
  }
};

void Can::emitAlive(uint16_t aliveFrameId) {
  unsigned long now = millis();
  if(aliveEmittingTimestamp + ALIVE_FRAME_FREQUENCY_MS <= now){
    aliveEmittingTimestamp = now;
    CANMessage frame;
    frame.id      = aliveFrameId;
    frame.len     = 1;
    frame.data[0] = aliveCounter;
    aliveCounter  = (aliveCounter + 1) % 3;
    emit(frame);
  }
};

void Can::emitdigitalAndAnalogPinsStatus(uint16_t digitalAndAnalogPinStatusesFrameId, uint8_t digitalPinsStatus [21], uint16_t analogPinsStatus [3]) {
  unsigned long now = millis();
  if(digitalAndAnalogPinStatusesTimestamp + DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS <= now){
    digitalAndAnalogPinStatusesTimestamp = now;
    CANMessage frame;
    frame.id  = digitalAndAnalogPinStatusesFrameId;
    frame.len = 8;

    for(uint8_t i = 0; i < 21; i++) {
      uint8_t frameNumber = i / 8;
      uint8_t bitNumber   = 7 - (i % 8);
      bitWrite(frame.data[frameNumber], bitNumber, digitalPinsStatus[i]);
    }

    frame.data[2] = frame.data[2]                                              | extractBits(analogPinsStatus[0], 0b00000011100000, 5);
    frame.data[3] = extractBits(analogPinsStatus[0], 0b00000000011111, 0) << 3 | extractBits(analogPinsStatus[0], 0b11100000000000, 11);
    frame.data[4] = extractBits(analogPinsStatus[0], 0b00011100000000, 8) << 5 | extractBits(analogPinsStatus[1], 0b00000011111000, 3);
    frame.data[5] = extractBits(analogPinsStatus[1], 0b00000000000111, 0) << 5 | extractBits(analogPinsStatus[1], 0b11111000000000, 9);
    frame.data[6] = extractBits(analogPinsStatus[1], 0b00000100000000, 8) << 7 | extractBits(analogPinsStatus[2], 0b00000011111110, 1);
    frame.data[7] = extractBits(analogPinsStatus[2], 0b00000000000001, 0) << 7 | extractBits(analogPinsStatus[2], 0b11111100000000, 8) << 1;

    emit(frame);
  }
};


bool* Can::parseDigitalPinRequest() {
  static bool digitalPinRequest[21] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  uint8_t pinNumber = 0;
  for(uint8_t byteNumber = 0; byteNumber < 3; byteNumber++) {
    for (uint8_t i = 1; i < 8; i++) {
      if (pinNumber < 21) {
        digitalPinRequest[pinNumber] = (receivedFrame.data[byteNumber] >> 8 - i & 0b1);
        pinNumber++;
      } else {
        i = 8;
      }
    }
  }
  return digitalPinRequest;
};

OtherPinDutyCycles Can::parseOtherPinRequest() {
  OtherPinDutyCycles otherPinDutyCycles;

  otherPinDutyCycles.pwmDutyCyles[0] = extractBits(receivedFrame.data[1], 0b11110000, 4) << 8 | receivedFrame.data[0];
  otherPinDutyCycles.pwmDutyCyles[1] = extractBits(receivedFrame.data[2], 0b00001111, 0) << 8 | extractBits(receivedFrame.data[1], 0b00001111, 0) << 4 |  extractBits(receivedFrame.data[2], 0b11110000, 4);
  otherPinDutyCycles.pwmDutyCyles[2] = extractBits(receivedFrame.data[4], 0b11110000, 4) << 4 | receivedFrame.data[3];
  otherPinDutyCycles.dacDutyCycle    = extractBits(receivedFrame.data[5], 0b00001111, 0) << 8 | extractBits(receivedFrame.data[4], 0b00001111, 0) << 4 |  extractBits(receivedFrame.data[5], 0b11110000, 4);

  return otherPinDutyCycles;
}

uint8_t Can::extractBits(uint16_t source, uint16_t mask, uint8_t shiftRight) {
  return (source & mask) >> shiftRight;
};