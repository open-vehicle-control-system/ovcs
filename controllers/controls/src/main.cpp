#include <Arduino.h>
#include <DebugLog.h>
#include <GearSelector.h>
#include <GearIndicator.h>
#include <OvcsMcp2515.h>
#include <ThrottlePedal.h>

#define DEBUGLOG_DEFAULT_LOG_LEVEL_TRACE
#define STATUS_NOT_INITIALIZED 0
#define STATUS_INITIALIZED 1
#define STATUS_ERROR 255

boolean initialized = false;
int status = STATUS_NOT_INITIALIZED;

OvcsMcp2515 transport       = OvcsMcp2515();
GearSelector gearSelector   = GearSelector();
GearIndicator gearIndicator = GearIndicator(&transport);
ThrottlePedal throttlePedal = ThrottlePedal();

boolean initializeAllComponents(){
    boolean transportInitialized     = transport.initialize();
    boolean gearSelectorInitialized  = gearSelector.initialize();
    boolean gearIndicatorInitialized = gearIndicator.initialize();
    boolean throttlePedalInitialized = throttlePedal.initialize();
    return transportInitialized && gearSelectorInitialized && gearIndicatorInitialized && throttlePedalInitialized;
}

void setup() {
    Serial.begin(9600);
    boolean initialized = initializeAllComponents();
    if(!initialized){
        status = STATUS_ERROR;
    } else {
        status = STATUS_INITIALIZED;
    }
}

void loop() {
    transport.sendKeepAlive(status);
    int selectedGear = gearSelector.getGearPosition(); // Get which position the gear selector is
    AnalogValues throttlePedalReadings = throttlePedal.readValues(); // Get readings from throttle pedal
    // Send frame through transport with aggregated data
    transport.sendFrame(MAX_ANALOG_READ_VALUE, throttlePedalReadings.pin_1, throttlePedalReadings.pin_2, selectedGear);
    
    int validatedGear = gearIndicator.getValidatedGearPosition(); // Get ECU validated gear
    gearIndicator.indicateGearPosition(validatedGear); // Light validated gear indicator
}