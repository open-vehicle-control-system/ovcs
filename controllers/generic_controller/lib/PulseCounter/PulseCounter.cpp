#include <PulseCounter.h>

void PulseCounter::recordEdge(uint32_t nowUs) {
  if (_count > 0 || _lastEdgeUs != 0) {
    uint32_t period = nowUs - _lastEdgeUs;
    if (period < PULSE_MIN_PERIOD_US) {
      return;
    }
    _periodUs = period;
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
  uint32_t sinceLastEdge = nowUs - _lastEdgeUs;
  if (sinceLastEdge > PULSE_TIMEOUT_US) {
    return 0;
  }
  uint32_t period = _periodUs > sinceLastEdge ? _periodUs : sinceLastEdge;
  uint32_t deciHz = 10000000UL / period;
  return deciHz > 65535UL ? 65535 : (uint16_t)deciHz;
};
