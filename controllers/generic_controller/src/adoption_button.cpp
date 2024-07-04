#include <adoption_button.h>

bool AdoptionButton::isWaitingAdoption() {
  if (adoptedSinceLastBoot) {
    return false;
  } else if (waitingAdoption) {
    return true;
  } else {
    waitingAdoption = digitalRead(ADOPTION_BUTTON_PIN) == HIGH;
    return waitingAdoption;
  }
};

void AdoptionButton::validateAdoption() {
  adoptedSinceLastBoot = true;
};