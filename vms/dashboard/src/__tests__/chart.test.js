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
const timing = { refreshInterval: 100, now: 1000 }

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
    const option = chartOption(block, [[], []], colors, timing)

    const within = { min: 0, max: 0 }
    expect(
      option.yAxis.map(({ min, max, name, position }) => ({ min: min(within), max: max(within), name, position }))
    ).toEqual([
      { min: -10, max: 10, name: 'km/h', position: undefined },
      { min: 0, max: 500, name: 'RPM', position: 'right' }
    ])
    expect('position' in option.yAxis[0]).toBe(false)
    expect(option.series.map(({ name, type, yAxisIndex, showSymbol }) => ({ name, type, yAxisIndex, showSymbol }))).toEqual([
      { name: 'Speed', type: 'line', yAxisIndex: 0, showSymbol: false },
      { name: 'RPM', type: 'line', yAxisIndex: 1, showSymbol: false }
    ])
    expect(option.animation).toBe(false)
  })

  it("leaves the series colours to ECharts and draws the rest in the theme's", () => {
    const option = chartOption(block, [[], []], colors, timing)

    expect(option.series.some((series) => 'color' in series)).toBe(false)
    expect('color' in option).toBe(false)
    expect(option.legend.textStyle.color).toBe('#111')
    expect(option.yAxis[0].axisLabel.color).toBe('#666')
    expect(option.yAxis[0].splitLine.lineStyle.color).toBe('#ccc')
    expect(option.tooltip.backgroundColor).toBe('#fff')
  })

  it('plots the points in seconds before now, over the whole window', () => {
    const option = chartOption(block, [[[700, 0], [900, 4]], []], colors, timing)

    expect(option.xAxis).toMatchObject({ type: 'value', min: -0.3, max: 0 })
    expect(option.series[0].data).toEqual([
      [-0.3, 0],
      [-0.1, 4]
    ])
    expect(option.xAxis.axisLabel.formatter(0)).toBe('now')
    expect(option.xAxis.axisLabel.formatter(-5)).toBe('-5 s')
  })

  it("keeps the value axes on the chart's edges rather than at now", () => {
    const option = chartOption(block, [[], []], colors, timing)
    expect(option.yAxis.map(({ axisLine }) => axisLine.onZero)).toEqual([false, false])
  })

  it('grows an axis to show a value beyond its bounds', () => {
    const [speed] = chartOption(block, [[], []], colors, timing).yAxis

    expect(speed.min({ min: -2, max: 3 })).toBe(-10)
    expect(speed.max({ min: -2, max: 3 })).toBe(10)
    expect(speed.min({ min: -14, max: 3 })).toBe(-14)
    expect(speed.max({ min: 0, max: 12.5 })).toBe(12.5)
  })

  it('reads the theme colours from the @ovcs/ui tokens', () => {
    document.documentElement.style.setProperty('--ovcs-text', '#010203')
    expect(themeColors().text).toBe('#010203')
    document.documentElement.style.removeProperty('--ovcs-text')
  })
})
