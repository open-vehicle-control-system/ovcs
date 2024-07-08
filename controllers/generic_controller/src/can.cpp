#include <can.h>

void Can::begin() {
  SPI.begin ();
  ACAN2517Settings settings (ACAN2517Settings::OSC_40MHz, 500UL * 1000UL);
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

uint8_t Can::extractBits(uint16_t source, uint16_t mask, uint8_t shiftRight) {
  return (source & mask) >> shiftRight;
};

void Can::emitdigitalAndAnalogPinsStatus(uint16_t digitalAndAnalogPinStatusesFrameId, uint8_t digitalPinsStatus [21], uint16_t analogPinsStatus [3]) {
  unsigned long now = millis();
  if(digitalAndAnalogPinStatusesTimestamp + DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS <= now){
    digitalAndAnalogPinStatusesTimestamp = now;
    CANMessage frame;
    frame.id  = digitalAndAnalogPinStatusesFrameId;
    frame.len = 8;
    for(uint8_t i=0; i < 21; i++) {
      uint8_t frameNumber = i / 8;
      uint8_t bitNumber   = 7 - (i % 8);
      bitWrite(frame.data[frameNumber], bitNumber, 1);
    }
    Serial.println("---------");
    Serial.println(analogPinsStatus[0]);
    Serial.println(analogPinsStatus[0], BIN);


    // frame.data[2] = frame.data[2]                                              | extractBits(analogPinsStatus[0], 0b00000000111000, 3);
    // frame.data[3] = extractBits(analogPinsStatus[0], 0b00000000000111, 0) << 5 | extractBits(analogPinsStatus[0], 0b11111000000000, 9);
    // frame.data[4] = extractBits(analogPinsStatus[0], 0b00000111000000, 6) << 5 | extractBits(analogPinsStatus[1], 0b00000000111110, 1);
    // frame.data[5] = extractBits(analogPinsStatus[1], 0b00000000000001, 0) << 7 | extractBits(analogPinsStatus[1], 0b11111110000000, 7);
    // frame.data[6] = extractBits(analogPinsStatus[1], 0b00000001000000, 6) << 7 | extractBits(analogPinsStatus[2], 0b00000000111111, 0) << 1 | extractBits(analogPinsStatus[2], 0b10000000000000, 13);
    // frame.data[7] = extractBits(analogPinsStatus[2], 0b01111111000000, 6) << 1;

    frame.data[2] = frame.data[2]                                              | extractBits(analogPinsStatus[0], 0b00000011100000, 5);
    frame.data[3] = extractBits(analogPinsStatus[0], 0b00000000011111, 0) << 3 | extractBits(analogPinsStatus[0], 0b11100000000000, 11);
    frame.data[4] = extractBits(analogPinsStatus[0], 0b00011100000000, 8) << 5;

    Serial.println(frame.data[2], BIN);
    Serial.println(frame.data[3], BIN);
    Serial.println(frame.data[4], BIN);
    emit(frame);
  }
};