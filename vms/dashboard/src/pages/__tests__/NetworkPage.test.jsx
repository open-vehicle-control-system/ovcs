import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, act } from '@testing-library/react'
import NetworkPage from '../NetworkPage.jsx'
import { dashboardSocket } from '../../services/socket.js'
import { useConnection } from '../../stores/connection.js'

vi.mock('../../services/socket.js', () => ({ dashboardSocket: { channel: vi.fn() } }))

const can0 = (rxBytes) => ({
  type: 'networkInterface',
  id: 'can0',
  attributes: {
    networkName: 'drivetrain',
    interfaceName: 'can0',
    spiInterfaceName: 'spi0.0',
    bitrate: 500000,
    statistics: {
      ifindex: 3,
      operstate: 'UP',
      txqlen: 10,
      linkinfo: { info_data: { bittiming: { bitrate: 500000 } } },
      stats64: {
        rx: { bytes: rxBytes, dropped: 0, errors: 1, multicast: 0, over_errors: 0, packets: 42, length_errors: 0, crc_errors: 0, frame_errors: 0, fifo_errors: 0, missed_errors: 0 },
        tx: { bytes: 64, carrier_errors: 0, collisions: 0, dropped: 0, errors: 0, packets: 8, aborted_errors: 0, fifo_errors: 0, window_errors: 0, heartbeat_errors: 0, carrier_changes: 2 }
      }
    }
  }
})

describe('NetworkPage', () => {
  let channel
  let update

  beforeEach(() => {
    channel = {
      on: vi.fn((event, callback) => (update = callback)),
      join: vi.fn(() => ({ receive() { return this } })),
      leave: vi.fn()
    }
    dashboardSocket.channel.mockReset()
    dashboardSocket.channel.mockReturnValue(channel)
  })

  it('joins network-interfaces every second and leaves when closed', () => {
    const { unmount } = render(<NetworkPage />)
    expect(dashboardSocket.channel).toHaveBeenCalledWith('network-interfaces', { interval: 1000 })
    expect(channel.join).toHaveBeenCalled()

    unmount()
    expect(channel.leave).toHaveBeenCalled()
  })

  it('lists each interface with its state and load', () => {
    render(<NetworkPage />)
    act(() => update({ data: [can0(1000)] }))
    act(() => update({ data: [can0(7250)] }))

    const row = screen.getByRole('row', { name: /drivetrain/ })
    expect(within(row).getByText('can0')).toBeTruthy()
    expect(within(row).getByText('spi0.0')).toBeTruthy()
    expect(within(row).getByText('UP').closest('.ovcs-status--ok')).toBeTruthy()
    expect(within(row).getByText('10 %')).toBeTruthy()
  })

  it('dims the last counters received while the dashboard is disconnected', () => {
    useConnection.setState({ state: 'disconnected' })
    render(<NetworkPage />)
    act(() => update({ data: [can0(1000)] }))

    expect(screen.getByRole('status').textContent).toMatch('last values received')
    expect(screen.getByRole('heading', { level: 3, name: 'can0' }).closest('.opacity-50')).toBeTruthy()
    act(() => useConnection.setState({ state: 'connected' }))
  })

  it('shows no load before the second sample', () => {
    render(<NetworkPage />)
    act(() => update({ data: [can0(1000)] }))
    const row = screen.getByRole('row', { name: /drivetrain/ })
    expect(within(row).getByText('—')).toBeTruthy()
  })

  it("shows each interface's counters in its own card", () => {
    render(<NetworkPage />)
    act(() => update({ data: [can0(1000)] }))

    const card = screen.getByRole('heading', { level: 3, name: 'can0' }).closest('.ovcs-card')
    expect(within(card).getByText('Carrier changes').nextElementSibling.textContent).toBe('2')
    expect(within(card).getAllByText('Packets').map((label) => label.nextElementSibling.textContent)).toEqual(['42', '8'])
    expect(within(card).getAllByText('Bytes').map((label) => label.nextElementSibling.textContent)).toEqual(['1 kB', '64 B'])
  })

  it('marks a counter that counts faults once it is not zero', () => {
    render(<NetworkPage />)
    act(() => update({ data: [can0(1000)] }))

    const card = screen.getByRole('heading', { level: 3, name: 'can0' }).closest('.ovcs-card')
    const [rxErrors] = within(card).getAllByText('Errors')
    expect(rxErrors.nextElementSibling.className).toMatch('text-ovcs-error-text')
    const [rxDropped] = within(card).getAllByText('Dropped')
    expect(rxDropped.nextElementSibling.className).not.toMatch('text-ovcs-error-text')
  })

  it('shows the bitrate in kbit/s', () => {
    render(<NetworkPage />)
    act(() => update({ data: [can0(1000)] }))
    expect(within(screen.getByRole('row', { name: /drivetrain/ })).getByText('500 kbit/s')).toBeTruthy()
  })

  it('shows unavailable statistics and recovers when the interface returns', () => {
    render(<NetworkPage />)
    const unavailable = can0(0)
    unavailable.attributes.statistics = {}
    act(() => update({ data: [unavailable] }))

    const row = screen.getByRole('row', { name: /drivetrain/ })
    expect(within(row).getByText('Unavailable')).toBeTruthy()
    expect(screen.getByText('Statistics unavailable')).toBeTruthy()
    expect(screen.queryByText('Packets')).toBeNull()

    act(() => update({ data: [can0(1000)] }))
    expect(within(row).getByText('UP')).toBeTruthy()
    expect(screen.queryByText('Statistics unavailable')).toBeNull()
    expect(screen.getAllByText('Packets')).toHaveLength(2)
  })

})
