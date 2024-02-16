#include <Arduino.h>
#include <DebugLog.h>
#include <TransportUtils.h>

#define THROTTLE_PEDAL_PIN_1 A0
#define THROTTLE_PEDAL_PIN_2 A1
#define DEBUGLOG_DEFAULT_LOG_LEVEL_TRACE
#define ANALOG_READ_RESOLUTION 14
#define MAX_ANALOG_READ_VALUE 16383
#define GEAR_DRIVE_PIN 2
#define DRIVE_INDICATOR_PIN 6
#define GEAR_NEUTRAL_PIN 3
#define NEUTRAL_INDICATOR_PIN 7
#define GEAR_REVERSE_PIN 4
#define REVERSE_INDICATOR_PIN 8
#define GEAR_PARKING_PIN 5
#define PARKING_INDICATOR_PIN 9
#define DRIVE 0
#define NEUTRAL 1
#define REVERSE 2
#define PARKING 3

boolean initialized = false;
int selectedGear = PARKING;
int validatedGear = PARKING;

void resetIndicators(){
  digitalWrite(DRIVE_INDICATOR_PIN, LOW);
  digitalWrite(NEUTRAL_INDICATOR_PIN, LOW);
  digitalWrite(REVERSE_INDICATOR_PIN, LOW);
  digitalWrite(PARKING_INDICATOR_PIN, LOW);
}

boolean initializeGearSelector(){
  pinMode(DRIVE_INDICATOR_PIN, OUTPUT);
  pinMode(NEUTRAL_INDICATOR_PIN, OUTPUT);
  pinMode(REVERSE_INDICATOR_PIN, OUTPUT);
  pinMode(PARKING_INDICATOR_PIN, OUTPUT);
  // Make sure there is no hardware fault on any of the gear shifter pins
  boolean noErrors = (digitalRead(DRIVE) == 1 && digitalRead(NEUTRAL) == 1 && digitalRead(REVERSE) == 1 && digitalRead(PARKING) == 1);
  return noErrors;
}

int setValidatedGear(){
  int gear = receiveValidatedGear();
  if(gear == PARKING || gear == REVERSE || gear == NEUTRAL || gear == DRIVE){
    return gear;
  } else {
    return validatedGear;
  }
}

boolean initializeController(){
  boolean transportHasErrors = initializeTransport();
  boolean gearSelectorInitialized = initializeGearSelector();
  return !transportHasErrors && gearSelectorInitialized;
}

void selectGearPosition(int driveGearStatus, int neutralGearStatus, int reverseGearStatus, int parkingGearStatus){
  if(driveGearStatus == 0 && neutralGearStatus == 1 && reverseGearStatus == 1 && parkingGearStatus == 1){
    selectedGear = DRIVE;
  } else if(driveGearStatus == 1 && neutralGearStatus == 0 && reverseGearStatus == 1 && parkingGearStatus == 1){
    selectedGear = NEUTRAL;
  } else if(driveGearStatus == 1 && neutralGearStatus == 1 && reverseGearStatus == 0 && parkingGearStatus == 1){
    selectedGear = REVERSE;
  } else if(driveGearStatus == 1 && neutralGearStatus == 1 && reverseGearStatus == 1 && parkingGearStatus == 0){
    selectedGear = PARKING;
  }
}

void indicateGearPosition(int gear){
  if(gear == PARKING){
    resetIndicators();
    digitalWrite(PARKING_INDICATOR_PIN, HIGH);
  } else if(gear == NEUTRAL){
    resetIndicators();
    digitalWrite(NEUTRAL_INDICATOR_PIN, HIGH);
  } else if(gear == REVERSE){
    resetIndicators();
    digitalWrite(REVERSE_INDICATOR_PIN, HIGH);
  } else if(gear == DRIVE){
    resetIndicators();
    digitalWrite(DRIVE_INDICATOR_PIN, HIGH);
  }
}

void setup() {
  Serial.begin(9600);
  initialized = initializeController();
  if(!initialized){
    LOG_ERROR("Controller cannot be initialized");
  }
}

void loop() {
  analogReadResolution(ANALOG_READ_RESOLUTION); // Set resolution to 14bits (max 16383) instead of 10bits (max 1023)
  int throttle_pedal_voltage_1 = analogRead(THROTTLE_PEDAL_PIN_1);
  int throttle_pedal_voltage_2 = analogRead(THROTTLE_PEDAL_PIN_2);
  int driveGearStatus        = digitalRead(GEAR_DRIVE_PIN);
  int neutralGearStatus      = digitalRead(GEAR_NEUTRAL_PIN);
  int reverseGearStatus      = digitalRead(GEAR_REVERSE_PIN);
  int parkingGearStatus      = digitalRead(GEAR_PARKING_PIN);
  selectGearPosition(driveGearStatus, neutralGearStatus, reverseGearStatus, parkingGearStatus);
  sendFrame(MAX_ANALOG_READ_VALUE, throttle_pedal_voltage_1, throttle_pedal_voltage_2, selectedGear);
  validatedGear = setValidatedGear();
  indicateGearPosition(validatedGear);
}