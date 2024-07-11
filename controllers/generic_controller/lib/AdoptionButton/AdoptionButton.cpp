#include <AdoptionButton.h>

bool AdoptionButton::isWaitingAdoption() {
  if (!waitingAdoption) {
    bool buttonPressed = digitalRead(ADOPTION_BUTTON_PIN) == HIGH;
    if(buttonPressed && !buttonWasPressed){
      waitingAdoption = true;
      adopted = false;
    }
    buttonWasPressed = buttonPressed;
  }
  return waitingAdoption;
};

void AdoptionButton::validateAdoption() {
  adopted         = true;
  waitingAdoption = false;
};