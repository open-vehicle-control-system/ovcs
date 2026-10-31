import { describe, it, expect, vi } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import App from '../App.jsx'
import { useStatus } from '../stores/status.js'
import { useParameters } from '../stores/parameters.js'

vi.mock('../services/parameters.js')
vi.mock('../services/socket.js', () => ({
  dashboardSocket: { channel: () => ({ on: () => {}, join: () => {}, off: () => {}, leave: () => {}, push: () => ({ receive() { return this } }) }) }
}))

const menuRenders = vi.hoisted(() => ({ count: 0 }))
vi.mock('../components/Menu.jsx', () => ({
  default: () => {
    menuRenders.count += 1
    return null
  }
}))

describe('App and the status', () => {
  it('shows each status in the top bar without rendering the rest of the page again', () => {
    useParameters.setState({ startPolling: vi.fn(), stopPolling: vi.fn() })
    render(<App />)
    const before = menuRenders.count

    act(() => useStatus.setState({ snapshot: { zenoh: 'connected', hailo: 'running', cpu_percent: 40, stereo_segment_percent: 50, cameras: {} } }))

    expect(screen.getByText('connected')).toBeTruthy()
    expect(menuRenders.count).toBe(before)
  })
})
