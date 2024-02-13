#include <ConvertionUtils.h>

// Parameters:
// value: analog pin value from 0 to 1023
// calibration_low: lowest value of calibration from 0 to 255
// calibration_high: highest value of calibration from 0 to 255
int convert_throttle_to_max_range(int value, int calibration_low, int calibration_high){
    int range = (calibration_high - calibration_low);
    int value_without_offset = value - (calibration_low*4);
    return ((value_without_offset*255)/(range))/4;
}