#include <GearIndicator.h>
#include <SPI.h>

int validatedGear = PARKING;

GearIndicator::GearIndicator(AbstractTransport* transport){
    _transport = transport;
}

void GearIndicator::reset(){
    digitalWrite(DRIVE_INDICATOR_PIN, LOW);
    digitalWrite(NEUTRAL_INDICATOR_PIN, LOW);
    digitalWrite(REVERSE_INDICATOR_PIN, LOW);
    digitalWrite(PARKING_INDICATOR_PIN, LOW);
}

boolean GearIndicator::initialize(){
    pinMode(DRIVE_INDICATOR_PIN, OUTPUT);
    pinMode(NEUTRAL_INDICATOR_PIN, OUTPUT);
    pinMode(REVERSE_INDICATOR_PIN, OUTPUT);
    pinMode(PARKING_INDICATOR_PIN, OUTPUT);
    reset();
    return true;
}

int GearIndicator::getValidatedGearPosition(){
    int gear = _transport->pullValidatedGear();
    if(gear == PARKING || gear == REVERSE || gear == NEUTRAL || gear == DRIVE){
        validatedGear = gear;
    }
    return validatedGear;
}

void GearIndicator::indicateGearPosition(int gear){
    if(gear == PARKING){
        GearIndicator::reset();
        digitalWrite(PARKING_INDICATOR_PIN, HIGH);
    } else if(gear == NEUTRAL){
        GearIndicator::reset();
        digitalWrite(NEUTRAL_INDICATOR_PIN, HIGH);
    } else if(gear == REVERSE){
        GearIndicator::reset();
        digitalWrite(REVERSE_INDICATOR_PIN, HIGH);
    } else if(gear == DRIVE){
        GearIndicator::reset();
        digitalWrite(DRIVE_INDICATOR_PIN, HIGH);
    }
}