import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, waitFor } from '@testing-library/react'
import DynamicPage from '../DynamicPage.jsx'
import { fetchBlocks } from '../../services/api.js'
import { useMetrics } from '../../stores/metrics.js'
import { useVehicle } from '../../stores/vehicle.js'
import { useConnection } from '../../stores/connection.js'

vi.mock('../../services/api.js')

const motion = 'Elixir.Motion'
const page = { id: 'status', name: 'Status' }

const table = (id, name, rows, extra = {}) => ({ id, name, subtype: 'table', fullWidth: null, rows, ...extra })
const metric = (key) => ({ type: 'metric', module: motion, key, name: key })

// A joined metrics channel that records what the page subscribes.
const listenToFakeChannel = () => {
  const channel = {
    on: () => {},
    onError: () => {},
    onClose: () => {},
    join: () => ({ receive: (status, callback) => (status === 'ok' ? callback() : null) }),
    push: vi.fn(),
    leave: () => {}
  }
  const stop = useMetrics.getState().listen({ channel: () => channel }, 70)
  return { pushes: () => channel.push.mock.calls, stop }
}

describe('DynamicPage', () => {
  let channel

  beforeEach(() => {
    vi.resetAllMocks()
    useMetrics.setState({ data: {}, units: {} })
    useVehicle.setState({ vehicle: { name: 'Mini', refreshInterval: 70 }, pages: [page], error: null })
    channel = listenToFakeChannel()
  })

  afterEach(() => channel.stop())

  const wideScreen = (wide) =>
    vi.stubGlobal('matchMedia', () => ({ matches: wide, addEventListener() {}, removeEventListener() {} }))

  const card = (name) => screen.getByRole('heading', { level: 3, name }).closest('.ovcs-card')

  it('renders each block in a card under its name', async () => {
    fetchBlocks.mockResolvedValue([table('motion', 'Motion', [metric('speed')])])
    render(<DynamicPage page={page} />)

    expect(screen.getByRole('heading', { level: 2, name: 'Status' })).toBeTruthy()
    expect(await screen.findByRole('heading', { level: 3, name: 'Motion' })).toBeTruthy()
    expect(card('Motion')).toBeTruthy()
    expect(fetchBlocks).toHaveBeenCalledWith('status')
  })

  it('stacks each column under its first block on a wide screen, a full-width block across the columns', async () => {
    wideScreen(true)
    fetchBlocks.mockResolvedValue([
      table('a', 'A', []),
      table('b', 'B', []),
      table('c', 'C', []),
      table('d', 'D', []),
      table('wide', 'Wide', [], { fullWidth: true })
    ])
    render(<DynamicPage page={page} />)
    await screen.findByRole('heading', { level: 3, name: 'D' })

    const firstColumn = card('A').parentElement
    expect(card('D').parentElement).toBe(firstColumn)
    expect(card('B').parentElement).not.toBe(firstColumn)
    expect(card('C').parentElement).not.toBe(card('B').parentElement)
    expect(card('Wide').parentElement).toBe(firstColumn.parentElement.parentElement)
    vi.unstubAllGlobals()
  })

  it('stacks every block in order in one column on a narrow screen', async () => {
    wideScreen(false)
    fetchBlocks.mockResolvedValue([table('a', 'A', []), table('b', 'B', []), table('c', 'C', [])])
    render(<DynamicPage page={page} />)
    await screen.findByRole('heading', { level: 3, name: 'C' })

    const column = card('A').parentElement
    expect([...column.children]).toEqual([card('A'), card('B'), card('C')])
    vi.unstubAllGlobals()
  })

  it('watches the page metrics while shown and releases them when left', async () => {
    fetchBlocks.mockResolvedValue([table('motion', 'Motion', [metric('speed'), metric('rpm')])])
    const { unmount } = render(<DynamicPage page={page} />)
    await waitFor(() =>
      expect(channel.pushes()).toEqual([
        ['subscribe', { module: motion, key: 'speed' }],
        ['subscribe', { module: motion, key: 'rpm' }]
      ])
    )

    unmount()
    expect(channel.pushes().slice(2)).toEqual([
      ['unsubscribe', { module: motion, key: 'speed' }],
      ['unsubscribe', { module: motion, key: 'rpm' }]
    ])
  })

  it('dims the last values received while the dashboard is disconnected', async () => {
    fetchBlocks.mockResolvedValue([table('motion', 'Motion', [metric('speed')])])
    useConnection.setState({ state: 'connected' })
    render(<DynamicPage page={page} />)
    await screen.findByRole('heading', { level: 3, name: 'Motion' })
    expect(screen.queryByRole('status')).toBe(null)

    act(() => useConnection.setState({ state: 'disconnected' }))
    expect((await screen.findByRole('status')).textContent).toMatch('last values received')
    expect(card('Motion').closest('.opacity-50')).toBeTruthy()

    act(() => useConnection.setState({ state: 'connected' }))
    await waitFor(() => expect(card('Motion').closest('.opacity-50')).toBe(null))
  })

  it('shows a failed blocks request under the page title', async () => {
    fetchBlocks.mockRejectedValue(new Error('GET /api/vehicle/pages/status/blocks: 500'))
    render(<DynamicPage page={page} />)
    expect((await screen.findByRole('alert')).textContent).toMatch('GET /api/vehicle/pages/status/blocks: 500')
  })

  it('ignores blocks that arrive after the page was left', async () => {
    let answer
    fetchBlocks.mockReturnValue(new Promise((resolve) => (answer = resolve)))
    const { unmount } = render(<DynamicPage page={page} />)

    unmount()
    await act(async () => answer([table('motion', 'Motion', [metric('speed')])]))

    expect(channel.pushes()).toEqual([])
    expect(screen.queryByRole('heading', { level: 3, name: 'Motion' })).toBe(null)
  })

  it('skips a block of an unknown subtype, which takes no column', async () => {
    wideScreen(true)
    fetchBlocks.mockResolvedValue([
      { id: 'gauge', name: 'Gauge', subtype: 'gauge' },
      table('motion', 'Motion', [metric('speed')])
    ])
    render(<DynamicPage page={page} />)

    await screen.findByRole('heading', { level: 3, name: 'Motion' })
    expect(screen.queryByRole('heading', { level: 3, name: 'Gauge' })).toBe(null)
    expect(card('Motion').parentElement.previousElementSibling).toBe(null)
    vi.unstubAllGlobals()
  })
})
