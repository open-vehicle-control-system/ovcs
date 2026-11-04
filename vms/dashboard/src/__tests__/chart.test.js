import { describe, it, expect } from 'vitest'
import { appendPoint, chartOption, seedPoints, themeColors } from '../chart.js'

const motion = 'Elixir.Motion'
const block = {
  id: 'speed',
  name: 'Speed & RPM',
  subtype: 'lineChart',
  serieMaxSize: 3,
  yAxis: [
    { min: -10, max: 10, label: 'km/h', series: [{ name: 'Speed', metric: { module: motion, key: 'speed' } }] },
    { min: 0, max: 500, label: 'RPM', position: 'right', series: [{ name: 'RPM', metric: { module: motion, key: 'rpm' } }] }
  ]
}
const colors = { text: '#111', muted: '#666', border: '#ccc', surface: '#fff' }

describe('chart', () => {
  it('starts each series with zeros spaced by the refresh interval, up to now', () => {
    expect(seedPoints(3, 100, 1000)).toEqual([
      [700, 0],
      [800, 0],
      [900, 0]
    ])
  })

  it('keeps at most the series size, dropping the oldest point', () => {
    const points = seedPoints(3, 100, 1000)
    expect(appendPoint(points, [1000, 5], 3)).toBe(points)
    expect(points).toEqual([
      [800, 0],
      [900, 0],
      [1000, 5]
    ])
  })

  it('puts each series on its axis, with the axis bounds, label and position', () => {
    const option = chartOption(block, [[], []], colors)

    expect(option.yAxis.map(({ min, max, name, position }) => ({ min, max, name, position }))).toEqual([
      { min: -10, max: 10, name: 'km/h', position: undefined },
      { min: 0, max: 500, name: 'RPM', position: 'right' }
    ])
    expect('position' in option.yAxis[0]).toBe(false)
    expect(option.series.map(({ name, type, yAxisIndex, showSymbol }) => ({ name, type, yAxisIndex, showSymbol }))).toEqual([
      { name: 'Speed', type: 'line', yAxisIndex: 0, showSymbol: false },
      { name: 'RPM', type: 'line', yAxisIndex: 1, showSymbol: false }
    ])
    expect(option.animation).toBe(false)
    expect(option.xAxis.type).toBe('time')
  })

  it("leaves the series colours to ECharts and draws the rest in the theme's", () => {
    const option = chartOption(block, [[], []], colors)

    expect(option.series.some((series) => 'color' in series)).toBe(false)
    expect('color' in option).toBe(false)
    expect(option.legend.textStyle.color).toBe('#111')
    expect(option.yAxis[0].axisLabel.color).toBe('#666')
    expect(option.yAxis[0].splitLine.lineStyle.color).toBe('#ccc')
    expect(option.tooltip.backgroundColor).toBe('#fff')
  })

  it('reads the theme colours from the @ovcs/ui tokens', () => {
    document.documentElement.style.setProperty('--ovcs-text', '#010203')
    expect(themeColors().text).toBe('#010203')
    document.documentElement.style.removeProperty('--ovcs-text')
  })
})
