    #include <ExpansionBoard.h>

    bool ExpansionBoard::begin() {
      Wire.begin();
      _board.begin();
      Wire.setClock(I2C_CLOCK_FREQUENCY);
    };

    void ExpansionBoard::pinMode(uint8_t pin, PinMode mode) {
      _board.pinMode1(pin, mode);
    };

    void ExpansionBoard::digitalWrite(uint8_t pin, PinStatus status) {
      _board.write1(pin, status);
    };

    PinStatus ExpansionBoard::digitalRead(uint8_t pin) {
      return static_cast<PinStatus>(_board.read1(pin));
    };