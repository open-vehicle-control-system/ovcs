#ifndef ADOPTION_BUTTON_H
#define ADOPTION_BUTTON_H

#include <Arduino.h>

#define ADOPTION_BUTTON_PIN 2

class AdoptionButton {
  public :
    bool adoptedSinceLastBoot;
    bool waitingAdoption;
    AdoptionButton() {
      pinMode(ADOPTION_BUTTON_PIN, INPUT);
      adoptedSinceLastBoot = false;
      waitingAdoption      = false;
    };

    bool isWaitingAdoption();
    void validateAdoption();
};

#endif