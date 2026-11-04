import { chartSeries } from './blocks.js'

/** A series' starting points: `size` zeros, `interval` apart, ending one interval before `now`. */
export const seedPoints = (size, interval, now) =>
  Array.from({ length: size }, (_, index) => [now - interval * (size - index), 0])

/** Appends `point`, dropping the oldest once `points` holds `size`; changes `points` in place and answers it. */
export function appendPoint(points, point, size) {
  if (points.length >= size) points.shift()
  points.push(point)
  return points
}

// ECharts draws on a canvas and does not read CSS variables.
const token = (style, name) => style.getPropertyValue(name).trim()

/** The `@ovcs/ui` colours of the page's current theme. */
export function themeColors() {
  const style = window.getComputedStyle(document.documentElement)
  return {
    text: token(style, '--ovcs-text'),
    muted: token(style, '--ovcs-text-muted'),
    border: token(style, '--ovcs-border'),
    surface: token(style, '--ovcs-surface')
  }
}

const axis = ({ min, max, label, position }, colors) => ({
  min,
  max,
  ...(position ? { position } : {}),
  name: label,
  type: 'value',
  nameLocation: 'end',
  nameTextStyle: { align: 'right', padding: 10, color: colors.muted },
  axisLabel: { color: colors.muted },
  axisLine: { lineStyle: { color: colors.border } },
  splitLine: { lineStyle: { color: colors.border } }
})

/** A line chart block's ECharts option; the series keep ECharts' own palette. */
export function chartOption(block, buffers, colors) {
  const series = chartSeries(block)
  return {
    animation: false,
    tooltip: {
      trigger: 'axis',
      backgroundColor: colors.surface,
      borderColor: colors.border,
      textStyle: { color: colors.text }
    },
    legend: {
      show: true,
      type: 'plain',
      bottom: 10,
      icon: 'circle',
      data: series.map(({ name }) => name),
      textStyle: { color: colors.text }
    },
    xAxis: { type: 'time', axisLabel: { show: false }, axisLine: { lineStyle: { color: colors.border } } },
    yAxis: block.yAxis.map((yAxis) => axis(yAxis, colors)),
    series: series.map(({ name, yAxisIndex }, index) => ({
      name,
      type: 'line',
      showSymbol: false,
      yAxisIndex,
      data: buffers[index]
    }))
  }
}
