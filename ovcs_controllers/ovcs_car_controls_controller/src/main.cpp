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
int selected_gear = PARKING;
int validated_gear = PARKING;

void reset_indicators(){
  digitalWrite(DRIVE_INDICATOR_PIN, LOW);
  digitalWrite(NEUTRAL_INDICATOR_PIN, LOW);
  digitalWrite(REVERSE_INDICATOR_PIN, LOW);
  digitalWrite(PARKING_INDICATOR_PIN, LOW);
}

boolean initialize_gear_selector(){
  pinMode(DRIVE_INDICATOR_PIN, OUTPUT);
  pinMode(NEUTRAL_INDICATOR_PIN, OUTPUT);
  pinMode(REVERSE_INDICATOR_PIN, OUTPUT);
  pinMode(PARKING_INDICATOR_PIN, OUTPUT);
  return true;
}

int set_validated_gear(){
  int gear = receive_validated_gear();
  if(gear == PARKING || gear == REVERSE || gear == NEUTRAL || gear == DRIVE){
    return gear;
  } else {
    return validated_gear;
  }
}

boolean initialize_controller(){
  boolean transport_has_errors = initialize_transport();
  boolean gear_selector_initialized = initialize_gear_selector();
  return !transport_has_errors && gear_selector_initialized;
}

void select_gear_position(int drive_gear_status, int neutral_gear_status, int reverse_gear_status, int parking_gear_status){
  if(drive_gear_status == 0 && neutral_gear_status == 1 && reverse_gear_status == 1 && parking_gear_status == 1){
    selected_gear = DRIVE;
  } else if(drive_gear_status == 1 && neutral_gear_status == 0 && reverse_gear_status == 1 && parking_gear_status == 1){
    selected_gear = NEUTRAL;
  } else if(drive_gear_status == 1 && neutral_gear_status == 1 && reverse_gear_status == 0 && parking_gear_status == 1){
    selected_gear = REVERSE;
  } else if(drive_gear_status == 1 && neutral_gear_status == 1 && reverse_gear_status == 1 && parking_gear_status == 0){
    selected_gear = PARKING;
  }
}

void indicate_gear_position(int gear){
  if(gear == PARKING){
    reset_indicators();
    digitalWrite(PARKING_INDICATOR_PIN, HIGH);
  } else if(gear == NEUTRAL){
    reset_indicators();
    digitalWrite(NEUTRAL_INDICATOR_PIN, HIGH);
  } else if(gear == REVERSE){
    reset_indicators();
    digitalWrite(REVERSE_INDICATOR_PIN, HIGH);
  } else if(gear == DRIVE){
    reset_indicators();
    digitalWrite(DRIVE_INDICATOR_PIN, HIGH);
  }
}

void setup() {
  Serial.begin(9600);
  initialized = initialize_controller();
  if(!initialized){
    LOG_ERROR("Controller cannot initialize");
  }
}

void loop() {
  analogReadResolution(ANALOG_READ_RESOLUTION); // Set resolution to 14bits (max 16383) instead of 10bits (max 1023)
  int throttle_pedal_voltage_1 = analogRead(THROTTLE_PEDAL_PIN_1);
  int throttle_pedal_voltage_2 = analogRead(THROTTLE_PEDAL_PIN_2);
  int drive_gear_status        = digitalRead(GEAR_DRIVE_PIN);
  int neutral_gear_status      = digitalRead(GEAR_NEUTRAL_PIN);
  int reverse_gear_status      = digitalRead(GEAR_REVERSE_PIN);
  int parking_gear_status      = digitalRead(GEAR_PARKING_PIN);
  select_gear_position(drive_gear_status, neutral_gear_status, reverse_gear_status, parking_gear_status);
  send_message(MAX_ANALOG_READ_VALUE, throttle_pedal_voltage_1, throttle_pedal_voltage_2, selected_gear);
  validated_gear = set_validated_gear();
  indicate_gear_position(validated_gear);
}