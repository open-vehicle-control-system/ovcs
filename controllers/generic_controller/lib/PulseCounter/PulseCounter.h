#ifndef PULSE_COUNTER_H
#define PULSE_COUNTER_H

#include <stdint.h>

// No edge for this long reads as stopped. It also sets the lowest
// frequency that can be reported: 1 Hz.
#define PULSE_TIMEOUT_US 1000000UL
// Edges closer than this are contact bounce or electrical noise, not a
// hall sensor: 100 us is 10 kHz, far above anything a wheel produces.
#define PULSE_MIN_PERIOD_US 100UL

// Turns the edges of a pulse train into a frequency. Pure arithmetic on
// the caller's clock, so the interrupt handler feeds it and the tests
// drive it without hardware.
class PulseCounter {
  public:
    PulseCounter() {
      _count      = 0;
      _lastEdgeUs = 0;
      _periodUs   = 0;
    };

    // Called from the interrupt handler with the current micros().
    void recordEdge(uint32_t nowUs);

    // Edges since boot, wrapping at 65535.
    uint16_t count();

    // Tenths of a hertz, 0 when stopped. The period used is the longer
    // of the last measured period and the time since the last edge, so
    // a decelerating wheel reads lower on every tick instead of holding
    // its last speed until the timeout.
    uint16_t frequencyDeciHz(uint32_t nowUs);

  private:
    volatile uint16_t _count;
    volatile uint32_t _lastEdgeUs;
    volatile uint32_t _periodUs;
};

#endif
