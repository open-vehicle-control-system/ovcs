#include <InitializationHelpers.h>

boolean InitializationHelpers::initializeController(){
  boolean transportHasErrors = Transport::initialize();
  boolean gearSelectorInitialized = initializeGearSelector();
  return !transportHasErrors && gearSelectorInitialized;
}

void InitializationHelpers::resetIndicators(){
  digitalWrite(DRIVE_INDICATOR_PIN, LOW);
  digitalWrite(NEUTRAL_INDICATOR_PIN, LOW);
  digitalWrite(REVERSE_INDICATOR_PIN, LOW);
  digitalWrite(PARKING_INDICATOR_PIN, LOW);
}

boolean InitializationHelpers::initializeGearSelector(){
  pinMode(DRIVE_INDICATOR_PIN, OUTPUT);
  pinMode(NEUTRAL_INDICATOR_PIN, OUTPUT);
  pinMode(REVERSE_INDICATOR_PIN, OUTPUT);
  pinMode(PARKING_INDICATOR_PIN, OUTPUT);
  // Make sure there is no hardware fault on any of the gear shifter pins
  boolean noErrors = (digitalRead(DRIVE) == 1 && digitalRead(NEUTRAL) == 1 && digitalRead(REVERSE) == 1 && digitalRead(PARKING) == 1);
  return noErrors;
}