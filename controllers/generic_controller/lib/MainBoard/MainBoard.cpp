    #include <MainBoard.h>

    bool MainBoard::begin() { return true; };

    void MainBoard::pinMode(uint8_t pin, uint8_t mode) {
      pinMode(pin, mode);
    };

    void MainBoard::digitalWrite(uint8_t pin, uint8_t value) {
      digitalWrite(pin, value);
    };

    uint8_t MainBoard::digitalRead(uint8_t pin) {
      return digitalRead(pin);
    };