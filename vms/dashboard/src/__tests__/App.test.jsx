import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import App from '../App.jsx'
import { fetchBlocks, fetchBoard, fetchFirmware, fetchPages, fetchVehicle } from '../services/api.js'
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
const firmware = { revision: 'ce99e251', target: 'host', nervesSystem: null, nervesSystemVersion: null, vehicle: 'OVCS Mini' }
const pages = [
  { id: 'status', name: 'Status' },
  { id: 'drive', name: 'Drive' }
]

// Opens the dashboard at `path`, as a reload would.
const visit = (path) => {
  window.history.replaceState(null, '', path)
  useNavigation.setState({ path })
}

const board = {
  data: {
    type: 'boards',
    id: 'current',
    attributes: { interfaces: [{ name: 'eth0', addresses: ['192.168.1.20'] }], time: '2026-11-11T14:53:12Z', clockSynchronized: true }
  }
}

describe('App', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    fetchVehicle.mockResolvedValue(vehicle)
    fetchPages.mockResolvedValue(pages)
    fetchBlocks.mockResolvedValue([])
    fetchFirmware.mockResolvedValue(firmware)
    fetchBoard.mockResolvedValue(board)
    useVehicle.setState({ vehicle: null, pages: null, error: null })
    useConnection.setState({ state: 'connecting' })
    document.title = 'OVCS VMS'
    visit('/')
  })

  it('renders the OVCS VMS top bar', async () => {
    render(<App />)
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/OVCS\s*VMS/)
    await screen.findByRole('heading', { level: 2, name: 'Status' })
  })

  it('reads the firmware and the board once connected, for the top bar and the browser title', async () => {
    render(<App />)
    await screen.findByRole('heading', { level: 2, name: 'Status' })
    expect(fetchFirmware).not.toHaveBeenCalled()
    expect(fetchBoard).not.toHaveBeenCalled()

    act(() => useConnection.setState({ state: 'connected' }))
    const topBar = screen.getByRole('heading', { level: 1 }).closest('header')
    expect(await within(topBar).findByText('OVCS Mini')).toBeTruthy()
    // The interfaces are behind the details button, which only a board read shows.
    fireEvent.click(await within(topBar).findByRole('button', { name: 'Board and firmware details' }))
    expect(within(topBar).getByText('192.168.1.20')).toBeTruthy()
    // The title is set in an effect, which can run after the text shows.
    await waitFor(() => expect(document.title).toBe('OVCS VMS · OVCS Mini'))
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

  it('shows the network page of a vehicle without pages', async () => {
    fetchPages.mockResolvedValue([])
    visit('/network')
    render(<App />)
    expect(await screen.findByRole('heading', { level: 2, name: 'Network' })).toBeTruthy()
  })

  it('rewrites a trailing slash away', async () => {
    visit('/drive/')
    render(<App />)
    await screen.findByRole('heading', { level: 2, name: 'Drive' })
    expect(window.location.pathname).toBe('/drive')
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
    await screen.findByRole('heading', { level: 2, name: 'Status' })
    expect(dashboardSocket.channel).toHaveBeenCalledWith('metrics', { interval: 70 })
  })

  it('shows in the bottom bar whether the dashboard is connected to the VMS', async () => {
    render(<App />)
    const footer = screen.getByRole('contentinfo')
    expect(footer.textContent).toBe('VMSConnecting…')

    act(() => useConnection.setState({ state: 'connected' }))
    expect(within(footer).getByText('Connected')).toBeTruthy()
    await screen.findByRole('heading', { level: 2, name: 'Status' })
  })
})
