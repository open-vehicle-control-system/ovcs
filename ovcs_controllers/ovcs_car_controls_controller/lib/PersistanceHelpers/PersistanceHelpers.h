#ifndef PersistanceHelpers_h
#define PersistanceHelpers_h

void save_calibration_data(char* label, int value);
int read_calibration_data(char* label);
int get_addr(char* pedal);

#endif