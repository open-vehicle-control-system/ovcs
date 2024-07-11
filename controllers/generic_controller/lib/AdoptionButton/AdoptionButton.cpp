#include <AdoptionButton.h>

bool AdoptionButton::isWaitingAdoption() {
  if (!waitingAdoption) {
    bool adoptionRequested = digitalRead(ADOPTION_BUTTON_PIN) == HIGH;
    if(adoptionRequested){
      waitingAdoption = true;
      adopted = false;
    }
  }
  return waitingAdoption;
};

void AdoptionButton::validateAdoption() {
  adopted         = true;
  waitingAdoption = false;
};