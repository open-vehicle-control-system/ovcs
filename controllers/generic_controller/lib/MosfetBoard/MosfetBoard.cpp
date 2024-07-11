    #include <MosfetBoard.h>

    bool MosfetBoard::begin() {
      Wire.begin();
      _board.begin();
      Wire.setClock(I2C_CLOCK_FREQUENCY);
    };

    void MosfetBoard::pinMode(uint8_t pin, uint8_t mode) {
      _board.pinMode1(pin, mode);
    };

    void MosfetBoard::digitalWrite(uint8_t pin, uint8_t value) {
      if (value == 1) {
        Serial.println("MOSFET");
        Serial.println(pin);
        Serial.println(value);
      }
      _board.write1(pin, value);
    };

    uint8_t MosfetBoard::digitalRead(uint8_t pin) {
      return _board.read1(pin);
    };