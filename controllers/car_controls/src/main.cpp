#include <Arduino.h>
#include <DebugLog.h>
#include <Transport.h>
#include <GearSelector.h>
#include <GearIndicator.h>
#include <ThrottlePedal.h>

#define DEBUGLOG_DEFAULT_LOG_LEVEL_TRACE

boolean initialized = false;

Transport transport = Transport();
GearSelector gearSelector = GearSelector();
GearIndicator gearIndicator = GearIndicator(transport);
ThrottlePedal throttlePedal = ThrottlePedal();

boolean initializeAllComponents(){
    boolean transportInitialized = transport.initialize();
    boolean gearSelectorInitialized = gearSelector.initialize();
    boolean gearIndicatorInitialized = gearIndicator.initialize();
    return transportInitialized && gearSelectorInitialized && gearIndicatorInitialized;
}

void setup() {
    Serial.begin(9600);
    boolean initialized = initializeAllComponents();
    if(!initialized){
      LOG_ERROR("Controller cannot be initialized");
    }
}

void loop() {
    int selectedGear = gearSelector.getGearPosition(); // Get which position the gear selector is
    int* throttlePedalReadings = throttlePedal.readValues(); // Get readings from throttle pedal

    // Send frame through transport with aggregated data
    transport.sendFrame(MAX_ANALOG_READ_VALUE, throttlePedalReadings.pin_1, throttlePedalReadings.pin_2, selectedGear);
    int validatedGear = gearIndicator.getValidatedGearPosition(); // Get ECU validated gear
    gearIndicator.indicateGearPosition(validatedGear); // Light validated gear indicator
}