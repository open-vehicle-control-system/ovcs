#ifndef ADOPTION_BUTTON_H
#define ADOPTION_BUTTON_H

#include <Arduino.h>

#define ADOPTION_BUTTON_PIN 2

class AdoptionButton {
  public :
    AdoptionButton() {
      pinMode(ADOPTION_BUTTON_PIN, INPUT);
      waitingAdoption      = false;
      adopted              = false;
      buttonWasPressed    = false;
    };

    bool isWaitingAdoption();
    void validateAdoption();

  private:
    bool waitingAdoption;
    bool adopted;
    bool buttonWasPressed;
};

#endif