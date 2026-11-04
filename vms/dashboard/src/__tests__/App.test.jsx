import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import App from '../App.jsx'
import { fetchBlocks, fetchPages, fetchVehicle } from '../services/api.js'
import { useVehicle } from '../stores/vehicle.js'
import { useNavigation } from '../stores/navigation.js'
import { useConnection } from '../stores/connection.js'
import { dashboardSocket } from '../services/socket.js'

vi.mock('../services/api.js')
vi.mock('../services/socket.js', () => {
  const push = () => ({ receive() { return this } })
  const channel = {
    on: () => {},
    onError: () => {},
    onClose: () => {},
    join: () => ({ receive() { return this } }),
    leave: () => {},
    push
  }
  return {
    dashboardSocket: {
      onOpen: () => 'r1',
      onClose: () => 'r2',
      onError: () => 'r3',
      off: () => {},
      isConnected: () => false,
      channel: vi.fn(() => channel)
    }
  }
})

const vehicle = { name: 'Mini', refreshInterval: 70 }
const pages = [
  { id: 'status', name: 'Status' },
  { id: 'drive', name: 'Drive' }
]

// Opens the dashboard at `path`, as a reload would.
const visit = (path) => {
  window.history.replaceState(null, '', path)
  useNavigation.setState({ path })
}

describe('App', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    fetchVehicle.mockResolvedValue(vehicle)
    fetchPages.mockResolvedValue(pages)
    fetchBlocks.mockResolvedValue([])
    useVehicle.setState({ vehicle: null, pages: null, error: null })
    useConnection.setState({ state: 'connecting' })
    document.title = 'OVCS VMS'
    visit('/')
  })

  it('renders the OVCS VMS top bar', async () => {
    render(<App />)
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/OVCS\s*VMS/)
    await screen.findByText('Mini')
  })

  it('shows the vehicle name and sets the browser title', async () => {
    render(<App />)
    expect(await screen.findByText('Mini')).toBeTruthy()
    expect(document.title).toBe('Mini VMS')
  })

  it('shows the first page at /', async () => {
    render(<App />)
    expect((await screen.findByRole('heading', { level: 2, name: 'Status' })).textContent).toBe('Status')
  })

  it('shows a page at its path, with its blocks', async () => {
    fetchBlocks.mockResolvedValue([{ id: 'motion', name: 'Motion', subtype: 'table', rows: [] }])
    visit('/drive')
    render(<App />)
    expect(await screen.findByRole('heading', { level: 2, name: 'Drive' })).toBeTruthy()
    expect(await screen.findByRole('heading', { level: 3, name: 'Motion' })).toBeTruthy()
    expect(fetchBlocks).toHaveBeenCalledWith('drive')
  })

  it('shows the network page at /network', async () => {
    visit('/network')
    render(<App />)
    expect(await screen.findByRole('heading', { level: 2, name: 'Network' })).toBeTruthy()
    expect(dashboardSocket.channel).toHaveBeenCalledWith('network-interfaces', { interval: 1000 })
  })

  it('rewrites an unknown path to /', async () => {
    visit('/nope')
    render(<App />)
    await screen.findByRole('heading', { level: 2, name: 'Status' })
    expect(window.location.pathname).toBe('/')
  })

  it('says the VMS cannot be reached and recovers on Retry', async () => {
    fetchVehicle.mockRejectedValueOnce(new Error('Cannot reach the VMS'))
    render(<App />)

    expect((await screen.findByRole('alert')).textContent).toMatch('Cannot reach the VMS')
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))

    expect(await screen.findByRole('heading', { level: 2, name: 'Status' })).toBeTruthy()
    expect(screen.queryByRole('alert')).toBe(null)
  })

  it("joins the metrics channel with the vehicle's refresh interval", async () => {
    render(<App />)
    await screen.findByText('Mini')
    expect(dashboardSocket.channel).toHaveBeenCalledWith('metrics', { interval: 70 })
  })

  it('shows whether the dashboard is connected', async () => {
    render(<App />)
    expect(screen.getByText('Connecting…')).toBeTruthy()
    await screen.findByText('Mini')
  })
})
