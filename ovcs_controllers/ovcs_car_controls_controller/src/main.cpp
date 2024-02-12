#include <DebugLog.h>
#include <CanUtils.h>
#include <PersistanceHelpers.h>

#define THROTTLE_PEDAL_PIN A0
#define DEBUGLOG_DEFAULT_LOG_LEVEL_TRACE

MCP2515 can_0(10);
can_frame calibration_message;

int initialized = false;
int calibration_mode = false;
int was_in_calibration_mode = false;

int throttle_pedal_calibration_low = 1023;
int throttle_pedal_calibration_high = 0;

boolean initialize_throttle_values(){
  throttle_pedal_calibration_low = read_calibration_data("throttle_low")*4;
  throttle_pedal_calibration_high = read_calibration_data("throttle_high")*4;
  return true;
}

boolean initialize_controller(){
  boolean can_has_errors = initialize_can(can_0);
  return !can_has_errors && initialize_throttle_values();
}

void reset_values(){
  throttle_pedal_calibration_low = 1023;
  throttle_pedal_calibration_high = 0;
}

void listen_for_calibration_message() {
  calibration_message = read_can_message(can_0, 0x500);
  if(calibration_message.can_id == 0x500 && calibration_message.data[0] == 1){
    calibration_mode = true;
    if(was_in_calibration_mode == false){
      was_in_calibration_mode = true;
    }
    reset_values();
    LOG_INFO("System is now in calibration mode");
  }
  if(calibration_message.can_id == 0x500 && calibration_message.data[0] == 0){
    calibration_mode = false;
    if(was_in_calibration_mode == true){
      LOG_INFO("Was in calibration mode, saving values...");
      save_calibration_data("throttle_low", throttle_pedal_calibration_low/4);
      save_calibration_data("throttle_high", throttle_pedal_calibration_high/4);
      was_in_calibration_mode = false;
    }
  }
}

int convert_throttle_to_max_range(int value, int calibration_low, int calibration_high){
  int range = calibration_high - calibration_low;
  int value_without_offset = value - calibration_low;
  return (value_without_offset/4*255)/(range/4);
}

void setup() {
  Serial.begin(9600);
  initialized = initialize_controller();
  if(!initialized){
    LOG_ERROR("Controller cannot initialize");
  }
}

void loop() {
  listen_for_calibration_message();
  if(calibration_mode){
    int throttle_pedal_resistance = analogRead(THROTTLE_PEDAL_PIN);
    throttle_pedal_calibration_low = min(throttle_pedal_resistance, throttle_pedal_calibration_low);
    throttle_pedal_calibration_high = max(throttle_pedal_resistance, throttle_pedal_calibration_high);
  } else {
    was_in_calibration_mode = false;
    int throttle_pedal_resistance = analogRead(THROTTLE_PEDAL_PIN);
    int throttle = convert_throttle_to_max_range(throttle_pedal_resistance, throttle_pedal_calibration_low, throttle_pedal_calibration_high);
    send_throttle_message(can_0, throttle);
  }
}