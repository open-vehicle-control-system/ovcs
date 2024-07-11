#include <AdoptionButton.h>

bool AdoptionButton::isWaitingAdoption() {
  if (!_waitingAdoption) {
    bool buttonPressed = digitalRead(ADOPTION_BUTTON_PIN) == HIGH;
    if(buttonPressed && !_buttonWasPressed){
      _waitingAdoption = true;
      _adopted         = false;
    }
    _buttonWasPressed = buttonPressed;
  }
  return _waitingAdoption;
};

void AdoptionButton::validateAdoption() {
  _adopted         = true;
  _waitingAdoption = false;
};