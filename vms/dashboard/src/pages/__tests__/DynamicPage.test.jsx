import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import DynamicPage from '../DynamicPage.jsx'
import { fetchBlocks } from '../../services/api.js'
import { useMetrics } from '../../stores/metrics.js'
import { useVehicle } from '../../stores/vehicle.js'

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

  it('renders each block in a card under its name, a full-width one across the grid', async () => {
    fetchBlocks.mockResolvedValue([
      table('motion', 'Motion', [metric('speed')]),
      table('faults', 'Faults', [metric('dtcs')], { fullWidth: true })
    ])
    render(<DynamicPage page={page} />)

    expect(screen.getByRole('heading', { level: 2, name: 'Status' })).toBeTruthy()
    const motionCard = (await screen.findByRole('heading', { level: 3, name: 'Motion' })).closest('.ovcs-card')
    const faultsCard = screen.getByRole('heading', { level: 3, name: 'Faults' }).closest('.ovcs-card')
    expect(motionCard.className).not.toMatch('col-span-3')
    expect(faultsCard.className).toMatch('lg:col-span-3')
    expect(fetchBlocks).toHaveBeenCalledWith('status')
  })

  it('watches the page metrics while shown and releases them when left', async () => {
    fetchBlocks.mockResolvedValue([table('motion', 'Motion', [metric('speed'), metric('rpm')])])
    const { unmount } = render(<DynamicPage page={page} />)
    await screen.findByRole('heading', { level: 3, name: 'Motion' })

    expect(channel.pushes()).toEqual([
      ['subscribe', { module: motion, key: 'speed' }],
      ['subscribe', { module: motion, key: 'rpm' }]
    ])

    unmount()
    expect(channel.pushes().slice(2)).toEqual([
      ['unsubscribe', { module: motion, key: 'speed' }],
      ['unsubscribe', { module: motion, key: 'rpm' }]
    ])
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

  it('skips a block of an unknown subtype', async () => {
    fetchBlocks.mockResolvedValue([
      { id: 'gauge', name: 'Gauge', subtype: 'gauge' },
      table('motion', 'Motion', [metric('speed')])
    ])
    render(<DynamicPage page={page} />)

    await screen.findByRole('heading', { level: 3, name: 'Motion' })
    expect(screen.queryByRole('heading', { level: 3, name: 'Gauge' })).toBe(null)
  })
})
