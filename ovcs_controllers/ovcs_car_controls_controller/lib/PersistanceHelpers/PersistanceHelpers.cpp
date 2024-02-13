#include <PersistanceHelpers.h>

#define LABEL_SIZE 2

typedef struct address {
    char* name;
    int addr;
} address;

address addresses[LABEL_SIZE] = {
    {"throttle_low",0},
    {"throttle_high",1}
};

void save_calibration_data(char* label, int value){
    int addr = get_addr(label);
    if(addr != -1){
        EEPROM.update(addr, value);
    }
}

int read_calibration_data(char* label){
    int addr = get_addr(label);
    if(addr != -1){
        int value = EEPROM.read(addr);
        return value;
    }
    return -1;
}

int get_addr(char* label){
    for(int i=0; i<LABEL_SIZE; i++ ){
        if( strcmp( addresses[i].name, label)  == 0 ){
            return addresses[i].addr;
        }
    }
    return -1;
}