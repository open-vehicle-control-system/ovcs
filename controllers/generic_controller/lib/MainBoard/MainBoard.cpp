    #include <MainBoard.h>

    bool MainBoard::begin() { return true; };

    void MainBoard::pinMode(uint8_t pin, PinMode mode) {
      ::pinMode(pin, mode);
    };

    void MainBoard::digitalWrite(uint8_t pin, PinStatus status) {
      ::digitalWrite(pin, status);
    };

    PinStatus MainBoard::digitalRead(uint8_t pin) {
      return ::digitalRead(pin);
    };