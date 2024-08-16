    #include <MosfetBoard.h>

    bool MosfetBoard::begin() {
      Wire.begin();
      _board.begin();
      Wire.setClock(I2C_CLOCK_FREQUENCY);
    };

    void MosfetBoard::pinMode(uint8_t pin, PinMode mode) {
      _board.pinMode1(pin, mode);
    };

    void MosfetBoard::digitalWrite(uint8_t pin, PinStatus status) {
      _board.write1(pin, status);
    };

    uint8_t MosfetBoard::digitalRead(uint8_t pin) {
      return _board.read1(pin);
    };