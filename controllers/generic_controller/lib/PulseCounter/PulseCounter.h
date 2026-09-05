#ifndef PULSE_COUNTER_H
#define PULSE_COUNTER_H

#include <stdint.h>

// No edge for this long reads as stopped. It is also the lowest
// frequency that can be reported, 0.5 Hz, and how long after the wheels
// stop the speed reads zero. On the Mini's spur gear 0.5 Hz is about
// 0.2 km/h at the wheel.
#define PULSE_TIMEOUT_US 2000000UL
// Edges closer than this are chatter, not a revolution. A hall switch
// passed slowly through its threshold can toggle several times in a few
// milliseconds; 2 ms is 500 Hz, still four times what the Mini's spur
// gear reaches at full motor speed.
#define PULSE_MIN_PERIOD_US 2000UL

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
    // its last speed until the timeout. Reads `_lastEdgeUs` and
    // `_periodUs` as a pair, so the caller must hold interrupts off.
    uint16_t frequencyDeciHz(uint32_t nowUs);

  private:
    volatile uint16_t _count;
    volatile uint32_t _lastEdgeUs;
    volatile uint32_t _periodUs;
};

#endif
