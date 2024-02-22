#include <GearSelector.h>

int selectedGear = PARKING;

boolean GearSelector::initialize(){
  pinMode(GEAR_DRIVE_PIN, INPUT);
  pinMode(GEAR_NEUTRAL_PIN, INPUT);
  pinMode(GEAR_REVERSE_PIN, INPUT);
  pinMode(GEAR_PARKING_PIN, INPUT);
  boolean noErrors = (digitalRead(GEAR_DRIVE_PIN) == 1 && digitalRead(GEAR_NEUTRAL_PIN) == 1 && digitalRead(GEAR_REVERSE_PIN) == 1 && digitalRead(GEAR_PARKING_PIN) == 1);
  return noErrors;
}

int GearSelector::getGearPosition(){
    int driveGearStatus   = digitalRead(GEAR_DRIVE_PIN);
    int neutralGearStatus = digitalRead(GEAR_NEUTRAL_PIN);
    int reverseGearStatus = digitalRead(GEAR_REVERSE_PIN);
    int parkingGearStatus = digitalRead(GEAR_PARKING_PIN);

    if(driveGearStatus == 0 && neutralGearStatus == 1 && reverseGearStatus == 1 && parkingGearStatus == 1){
        selectedGear = DRIVE;
    } else if(driveGearStatus == 1 && neutralGearStatus == 0 && reverseGearStatus == 1 && parkingGearStatus == 1){
        selectedGear = NEUTRAL;
    } else if(driveGearStatus == 1 && neutralGearStatus == 1 && reverseGearStatus == 0 && parkingGearStatus == 1){
        selectedGear = REVERSE;
    } else if(driveGearStatus == 1 && neutralGearStatus == 1 && reverseGearStatus == 1 && parkingGearStatus == 0){
        selectedGear = PARKING;
    }
    return selectedGear;
}

void GearSelector::setGearPosition(int position){
    selectedGear = position;
}