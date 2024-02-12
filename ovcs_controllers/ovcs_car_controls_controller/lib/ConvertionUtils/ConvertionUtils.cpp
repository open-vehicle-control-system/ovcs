#include <ConvertionUtils.h>

int convert_throttle_to_max_range(int value, int calibration_low, int calibration_high){
  int range = calibration_high - calibration_low;
  int value_without_offset = value - calibration_low;
  return (value_without_offset/4*255)/(range/4);
}