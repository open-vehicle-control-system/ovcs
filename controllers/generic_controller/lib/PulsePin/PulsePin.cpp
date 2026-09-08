#include <PulsePin.h>

static PulseCounter pulseCounter0;

static void pulsePin0Isr() {
  pulseCounter0.recordEdge(micros());
};

bool PulsePin::readable() {
  return _enabled;
};

// Pulled up: a hall sensor with an open-collector output only ever
// pulls the line low, so without the pull-up it never rises and no edge
// is counted. A push-pull sensor is unaffected.
void PulsePin::begin() {
  if (readable()) {
    pinMode(_physicalPin, INPUT_PULLUP);
    attachInterrupt(digitalPinToInterrupt(_physicalPin), pulsePin0Isr, RISING);
  } else {
    // A re-adoption that disables the pin runs this without a reboot,
    // so the interrupt and the pull-up from the previous configuration
    // have to be undone here.
    detachInterrupt(digitalPinToInterrupt(_physicalPin));
    pinMode(_physicalPin, INPUT);
  }
};

// A single aligned 16-bit load is atomic on the Cortex-M4.
uint16_t PulsePin::count() {
  if (!readable()) {
    return 0;
  }
  return pulseCounter0.count();
};

// The period and the last edge are written together by the interrupt
// handler, so they are read together with interrupts off. The clock
// is sampled inside the guard too: an edge landing between the sample
// and the guard would otherwise sit in the future.
uint16_t PulsePin::frequencyDeciHz() {
  if (!readable()) {
    return 0;
  }
  noInterrupts();
  uint16_t frequency = pulseCounter0.frequencyDeciHz(micros());
  interrupts();
  return frequency;
};
