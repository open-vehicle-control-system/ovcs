#ifndef TransportUtils_h
#define TransportUtils_h

#include <Arduino.h>

boolean initialize_transport();
void send_message(int max_analog_read_value, int value_voltage_1, int value_voltage_2, int selected_gear);
int receive_validated_gear();

#endif