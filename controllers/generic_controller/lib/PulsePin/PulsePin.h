#ifndef PULSE_PIN_H
#define PULSE_PIN_H

#include <Arduino.h>
#include <OtherPin.h>
#include <PulseCounter.h>

// An input whose rising edges are counted by interrupt and reported as
// a frequency. One instance is supported: attachInterrupt() needs a
// free function, so the counter it feeds is a single static.
class PulsePin: public OtherPin {
  public:
    PulsePin() {};
    PulsePin(bool enabled, uint8_t physicalPin) : OtherPin(enabled, physicalPin) {};
    bool readable();
    // Configures the pin and attaches the interrupt. Safe to call again.
    void begin();
    uint16_t count();
    uint16_t frequencyDeciHz();
};

#endif
