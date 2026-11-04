import { describe, it, expect } from 'vitest'
import { chartSeries, pageMetrics } from '../blocks.js'

const motion = 'Elixir.VmsCore.Components.OVCS.VehicleMotion'
const steering = 'Elixir.VmsCore.Components.OVCS.SteeringColumn'

const table = {
  id: 'status',
  subtype: 'table',
  rows: [
    { type: 'metric', module: motion, key: 'speed' },
    { type: 'action', inputType: 'number', module: steering, action: 'set', statusMetricKey: 'kp' },
    { type: 'action', inputType: 'button', module: steering, action: 'reset', statusMetricKey: null },
    { type: 'metric', module: motion, key: 'speed' }
  ]
}

const chart = {
  id: 'speed',
  subtype: 'lineChart',
  serieMaxSize: 300,
  yAxis: [
    { min: 0, max: 10, label: 'km/h', series: [{ name: 'Speed', metric: { module: motion, key: 'speed' } }] },
    { min: 0, max: 500, label: 'RPM', series: [{ name: 'RPM', metric: { module: motion, key: 'rpm' } }] }
  ]
}

describe('blocks', () => {
  it("lists a page's metrics once each, in order of appearance", () => {
    expect(pageMetrics([table, chart])).toEqual([
      { module: motion, key: 'speed' },
      { module: steering, key: 'kp' },
      { module: motion, key: 'rpm' }
    ])
  })

  it("flattens a chart's series with the index of their axis", () => {
    expect(chartSeries(chart)).toEqual([
      { name: 'Speed', metric: { module: motion, key: 'speed' }, yAxisIndex: 0 },
      { name: 'RPM', metric: { module: motion, key: 'rpm' }, yAxisIndex: 1 }
    ])
  })
})
