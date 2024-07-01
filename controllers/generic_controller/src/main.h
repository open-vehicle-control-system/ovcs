#define DIGITAL_PIN_DISABLED 0
#define DIGITAL_PIN_READ_ONLY 1
#define DIGITAL_PIN_WRITE_ONLY 2
#define DIGITAL_PIN_READ_WRITE 3

#define ALIVE_FRAME_ID_MASK 0x700
#define DIGITAL_PIN_REQUEST_FRAME_ID_MASK 0x701
#define OTHER_PIN_REQUEST_FRAME_ID_MASK 0x702
#define DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK 0x703

class DigitalPinConfiguration {
  public : uint8_t status;
};

class OtherPinConfiguration {
  public : bool  enabled;
};

class Configuration {
  public :
    uint8_t  controllerId;
    DigitalPinConfiguration digitalPinConfigurations [21];
    OtherPinConfiguration pwmPinConfigurations [3];
    OtherPinConfiguration dacPinConfiguration;
    OtherPinConfiguration analogPinConfigurations [3];
    uint16_t aliveFrameId;
    uint16_t   digitalPinRequestFrameId;
    uint16_t otherPinRequestFrameId;
    uint16_t digitalAndAnalogPinStatusFrameId;
    Configuration() {};
    Configuration(uint8_t rawConfiguration [8]) {
      controllerId = rawConfiguration[0] >> 3;
      aliveFrameId                     = computeFrameId(ALIVE_FRAME_ID_MASK);
      digitalPinRequestFrameId         = computeFrameId(DIGITAL_PIN_REQUEST_FRAME_ID_MASK);
      otherPinRequestFrameId           = computeFrameId(OTHER_PIN_REQUEST_FRAME_ID_MASK);
      digitalAndAnalogPinStatusFrameId = computeFrameId(DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK);
    };
    uint16_t computeFrameId(uint16_t mask) {
      uint16_t shiftedId = controllerId << 3;
      return shiftedId | mask;
    };
};