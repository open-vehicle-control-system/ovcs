#ifndef ADOPTION_BUTTON_H
#define ADOPTION_BUTTON_H

#include <Arduino.h>
#include <Debug.h>

#define ADOPTION_BUTTON_PIN 2

class AdoptionButton {
  public :
    AdoptionButton() {
      pinMode(ADOPTION_BUTTON_PIN, INPUT);
      _waitingAdoption  = false;
      _adopted          = false;
      _buttonWasPressed = false;
    };

    bool isWaitingAdoption();
    void validateAdoption();

  private:
    bool _waitingAdoption;
    bool _adopted;
    bool _buttonWasPressed;
};

#endif