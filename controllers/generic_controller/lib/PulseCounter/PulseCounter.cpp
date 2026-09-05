#include <PulseCounter.h>

void PulseCounter::recordEdge(uint32_t nowUs) {
  if (_count > 0 || _lastEdgeUs != 0) {
    uint32_t period = nowUs - _lastEdgeUs;
    if (period < PULSE_MIN_PERIOD_US) {
      return;
    }
    // The first edge after a stop measures the stop, not a period; the
    // second one does.
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
  // An edge recorded after the caller sampled its clock reads as a
  // negative gap; treat it as "just now" rather than as a wraparound.
  int32_t gap = (int32_t)(nowUs - _lastEdgeUs);
  uint32_t sinceLastEdge = gap < 0 ? 0 : (uint32_t)gap;
  if (sinceLastEdge > PULSE_TIMEOUT_US) {
    // Forget the period, or the stale pair would re-enter the window
    // every time the clock wraps (71.6 min) and report motion at rest.
    // The next real edge measures a fresh period.
    _periodUs = 0;
    return 0;
  }
  uint32_t period = _periodUs > sinceLastEdge ? _periodUs : sinceLastEdge;
  uint32_t deciHz = 10000000UL / period;
  return deciHz > 65535UL ? 65535 : (uint16_t)deciHz;
};
