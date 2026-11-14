import { describe, it, expect, vi } from 'vitest'
import { render, screen, act, within } from '@testing-library/react'
import App from '../App.jsx'
import { useStatus } from '../stores/status.js'
import { useParameters } from '../stores/parameters.js'

vi.mock('../services/parameters.js')
vi.mock('../services/socket.js', () => ({
  dashboardSocket: { isConnected: () => true, onOpen: () => 'open', onClose: () => 'close', onError: () => 'error', off: () => {}, channel: () => ({ on: () => {}, join: () => ({ receive() { return this } }), off: () => {}, onError: () => {}, leave: () => {}, push: () => ({ receive() { return this } }) }) }
}))

const menuRenders = vi.hoisted(() => ({ count: 0 }))
vi.mock('../components/Menu.jsx', () => ({
  default: () => {
    menuRenders.count += 1
    return null
  }
}))

describe('App and the status', () => {
  it('shows each status in the bottom bar without rendering the rest of the page again', () => {
    useParameters.setState({ startPolling: vi.fn(), stopPolling: vi.fn() })
    render(<App />)
    const before = menuRenders.count

    const ros2 = { id: 'ros2_zenoh', name: 'ROS 2 · Zenoh', status: { level: 'ok', detail: 'Connected' } }
    act(() => useStatus.setState({ snapshot: { exporters: [ros2], npu: { kind: 'Hexagon', state: 'running' }, cpuPercent: 40, stereoLoadPercent: 50, cameras: {} } }))

    expect(within(screen.getByRole('contentinfo')).getByText('connected')).toBeTruthy()
    expect(menuRenders.count).toBe(before)
  })
})
