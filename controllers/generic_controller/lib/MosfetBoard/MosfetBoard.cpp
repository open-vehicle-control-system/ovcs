    #include <MosfetBoard.h>

    bool MosfetBoard::begin() {
      Wire.begin();
      board.begin();
      Wire.setClock(I2C_CLOCK_FREQUENCY);
    };

    void MosfetBoard::pinMode(uint8_t pin, uint8_t mode) {
      board.pinMode1(pin, mode);
    };

    void MosfetBoard::digitalWrite(uint8_t pin, uint8_t value) {
      board.write1(pin, value);
    };

    uint8_t MosfetBoard::digitalRead(uint8_t pin) {
      return board.read1(pin);
    };