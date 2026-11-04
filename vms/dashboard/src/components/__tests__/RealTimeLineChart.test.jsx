import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import { OvcsThemeSwitch } from '@ovcs/ui/react'
import { init } from 'echarts/core'
import RealTimeLineChart from '../RealTimeLineChart.jsx'
import Block from '../Block.jsx'
import { useMetrics } from '../../stores/metrics.js'

const chart = { setOption: vi.fn(), resize: vi.fn(), dispose: vi.fn() }

vi.mock('echarts/core', () => ({ use: vi.fn(), init: vi.fn(() => chart) }))
vi.mock('echarts/charts', () => ({ LineChart: {} }))
vi.mock('echarts/components', () => ({ GridComponent: {}, TooltipComponent: {}, LegendComponent: {} }))
vi.mock('echarts/renderers', () => ({ CanvasRenderer: {} }))

const motion = 'Elixir.Motion'
const steering = 'Elixir.Steering'
const block = {
  id: 'speed',
  name: 'Speed',
  subtype: 'lineChart',
  serieMaxSize: 3,
  yAxis: [
    {
      min: 0,
      max: 10,
      label: 'km/h',
      series: [
        { name: 'Speed', metric: { module: motion, key: 'speed' } },
        { name: 'Angle', metric: { module: steering, key: 'angle' } }
      ]
    }
  ]
}

const lastSeries = () => chart.setOption.mock.calls.at(-1)[0].series

describe('RealTimeLineChart', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    useMetrics.setState({ data: {}, units: {} })
    vi.stubGlobal(
      'ResizeObserver',
      class {
        observe() {}
        disconnect() {}
      }
    )
  })

  afterEach(() => vi.unstubAllGlobals())

  it('starts every series full of zeros', () => {
    render(<RealTimeLineChart block={block} refreshInterval={100} />)
    expect(init).toHaveBeenCalledTimes(1)
    expect(lastSeries().map((series) => series.data.length)).toEqual([3, 3])
  })

  it('appends one point per series with data on each push', () => {
    render(<RealTimeLineChart block={block} refreshInterval={100} />)

    act(() => useMetrics.setState({ data: { [motion]: { speed: 4 } } }))
    act(() => useMetrics.setState({ data: { [motion]: { speed: 5 } } }))

    const [speed, angle] = lastSeries()
    expect(speed.data.map(([, value]) => value)).toEqual([0, 4, 5])
    expect(angle.data.map(([, value]) => value)).toEqual([0, 0, 0])
  })

  it('follows the theme', () => {
    document.documentElement.style.setProperty('--ovcs-text', '#111111')
    render(
      <>
        <OvcsThemeSwitch />
        <RealTimeLineChart block={block} refreshInterval={100} />
      </>
    )
    expect(chart.setOption.mock.calls.at(-1)[0].legend.textStyle.color).toBe('#111111')

    document.documentElement.style.setProperty('--ovcs-text', '#eeeeee')
    fireEvent.click(screen.getByRole('switch'))
    expect(chart.setOption.mock.calls.at(-1)[0].legend.textStyle.color).toBe('#eeeeee')
    document.documentElement.style.removeProperty('--ovcs-text')
  })

  it('disposes the chart when unmounted, and stops following pushes', () => {
    const { unmount } = render(<RealTimeLineChart block={block} refreshInterval={100} />)
    unmount()
    expect(chart.dispose).toHaveBeenCalled()

    const calls = chart.setOption.mock.calls.length
    act(() => useMetrics.setState({ data: { [motion]: { speed: 4 } } }))
    expect(chart.setOption.mock.calls.length).toBe(calls)
  })

  it('is loaded by a lineChart block', async () => {
    render(<Block block={block} refreshInterval={100} />)
    expect(screen.getByRole('heading', { level: 3, name: 'Speed' })).toBeTruthy()
    await waitFor(() => expect(init).toHaveBeenCalled())
  })
})
