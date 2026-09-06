#include <PulseCounter.h>

void PulseCounter::recordEdge(uint32_t nowUs) {
  if (_stopped) {
    // The first edge after a stop measures the stop, not a period; the
    // second one does.
    _stopped = false;
  } else {
    uint32_t period = nowUs - _lastEdgeUs;
    if (period < PULSE_MIN_PERIOD_US) {
      return;
    }
    _periodUs = period > PULSE_TIMEOUT_US ? 0 : period;
  }
  _lastEdgeUs = nowUs;
  _count++;
};

uint16_t PulseCounter::count() {
  return _count;
};

uint16_t PulseCounter::frequencyDeciHz(uint32_t nowUs) {
  if (_periodUs == 0) {
    return 0;
  }
  // Unsigned on purpose: the caller samples the clock with interrupts
  // off, so an edge can never be newer than `nowUs`, and a stop long
  // enough to wrap the clock must still read as a stop.
  uint32_t sinceLastEdge = nowUs - _lastEdgeUs;
  if (sinceLastEdge > PULSE_TIMEOUT_US) {
    // Forget the period, or the stale pair would re-enter the window
    // every time the clock wraps (71.6 min) and report motion at rest.
    _periodUs = 0;
    _stopped  = true;
    return 0;
  }
  uint32_t period = _periodUs > sinceLastEdge ? _periodUs : sinceLastEdge;
  uint32_t deciHz = 10000000UL / period;
  return deciHz > 65535UL ? 65535 : (uint16_t)deciHz;
};
