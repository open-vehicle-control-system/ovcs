#include <PulsePin.h>

static PulseCounter pulseCounter0;

static void pulsePin0Isr() {
  pulseCounter0.recordEdge(micros());
};

bool PulsePin::readable() {
  return _enabled;
};

void PulsePin::begin() {
  if (readable()) {
    pinMode(_physicalPin, INPUT);
    attachInterrupt(digitalPinToInterrupt(_physicalPin), pulsePin0Isr, RISING);
  }
};

// The counter's fields are written from the interrupt handler, so they
// are read with interrupts off to get a consistent pair.
uint16_t PulsePin::count() {
  if (!readable()) {
    return 0;
  }
  noInterrupts();
  uint16_t count = pulseCounter0.count();
  interrupts();
  return count;
};

uint16_t PulsePin::frequencyDeciHz() {
  if (!readable()) {
    return 0;
  }
  uint32_t now = micros();
  noInterrupts();
  uint16_t frequency = pulseCounter0.frequencyDeciHz(now);
  interrupts();
  return frequency;
};
