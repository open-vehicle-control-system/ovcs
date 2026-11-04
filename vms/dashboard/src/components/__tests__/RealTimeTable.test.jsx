import { describe, it, expect, beforeEach } from 'vitest'
import { render, screen, within, act } from '@testing-library/react'
import RealTimeTable from '../RealTimeTable.jsx'
import { useMetrics } from '../../stores/metrics.js'

const motion = 'Elixir.Motion'
const metric = (key, extra = {}) => ({ type: 'metric', module: motion, key, name: key, ...extra })

const block = (rows) => ({ id: 'status', name: 'Status', subtype: 'table', rows })

const valueOf = (name) => screen.getByRole('row', { name: new RegExp(`^${name}`) }).querySelector('td')

describe('RealTimeTable', () => {
  beforeEach(() => useMetrics.setState({ data: {}, units: {} }))

  it("shows a number rounded and followed by its publisher's unit", () => {
    useMetrics.setState({ data: { [motion]: { speed: 12.346 } }, units: { [motion]: { speed: 'km/h' } } })
    render(<RealTimeTable block={block([metric('speed')])} />)
    expect(valueOf('speed').textContent).toBe('12.35 km/h')
  })

  it('shows a boolean as a check or a cross, named for a screen reader', () => {
    useMetrics.setState({ data: { [motion]: { ready: true, fault: false } } })
    render(<RealTimeTable block={block([metric('ready'), metric('fault')])} />)
    expect(within(valueOf('ready')).getByText('yes')).toBeTruthy()
    expect(valueOf('ready').querySelector('svg')).toBeTruthy()
    expect(within(valueOf('fault')).getByText('no')).toBeTruthy()
  })

  it('shows nothing until the module publishes', () => {
    render(<RealTimeTable block={block([metric('speed')])} />)
    expect(valueOf('speed').textContent).toBe('')
  })

  it('shows a dash for a key the module has not published', () => {
    useMetrics.setState({ data: { [motion]: { rpm: 1 } } })
    render(<RealTimeTable block={block([metric('speed')])} />)
    expect(valueOf('speed').textContent).toBe('—')
  })

  it("shows the row's hint under its name", () => {
    render(<RealTimeTable block={block([metric('speed', { hint: 'Measured at the wheels' })])} />)
    expect(screen.getByText('Measured at the wheels')).toBeTruthy()
  })

  it('shows a multi-line string as a monospace block', () => {
    useMetrics.setState({ data: { [motion]: { dtcs: 'P0300\nP0171' } } })
    render(<RealTimeTable block={block([metric('dtcs')])} />)
    expect(valueOf('dtcs').querySelector('.font-mono').textContent).toBe('P0300\nP0171')
  })

  it('follows each push', () => {
    useMetrics.setState({ data: { [motion]: { speed: 1 } } })
    render(<RealTimeTable block={block([metric('speed')])} />)
    act(() => useMetrics.setState({ data: { [motion]: { speed: 2 } } }))
    expect(valueOf('speed').textContent).toBe('2')
  })
})
