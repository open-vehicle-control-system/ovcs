import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import Firmware from '../Firmware.jsx'
import { useStatus } from '../../stores/status.js'

// The unit's answer to `GET /api/firmware`.
const answer = (attributes) => ({ ok: true, status: 200, json: async () => ({ data: { type: 'firmwares', id: 'current', attributes } }) })

const board = { revision: 'ce99e251', target: 'okdo_c100', nervesSystem: 'nerves_system_okdo_c100', nervesSystemVersion: '0.3.0' }

const flush = () => act(() => Promise.resolve())

describe('Firmware', () => {
  let fetchMock

  beforeEach(() => {
    fetchMock = vi.fn().mockResolvedValue(answer(board))
    vi.stubGlobal('fetch', fetchMock)
    useStatus.setState({ joins: 0 })
  })
  afterEach(() => vi.unstubAllGlobals())

  it('reads nothing before the unit is joined', async () => {
    const { container } = render(<Firmware />)
    await flush()

    expect(fetchMock).not.toHaveBeenCalled()
    expect(container.textContent).toBe('')
  })

  it("shows a board's commit and Nerves system, named for a screen reader", async () => {
    useStatus.setState({ joins: 1 })
    const { container } = render(<Firmware />)
    await flush()

    expect(container.textContent).toBe('Firmware ce99e251 · nerves_system_okdo_c100 0.3.0')
  })

  it('shows the target where there is no Nerves system, as on a host', async () => {
    fetchMock.mockResolvedValue(answer({ revision: 'ce99e251-dirty', target: 'host', nervesSystem: null, nervesSystemVersion: null }))
    useStatus.setState({ joins: 1 })
    render(<Firmware />)
    await flush()

    expect(screen.getByText('ce99e251-dirty · host')).toBeTruthy()
  })

  it('reads it again when the unit comes back, as after an upload', async () => {
    useStatus.setState({ joins: 1 })
    render(<Firmware />)
    await flush()

    fetchMock.mockResolvedValue(answer({ ...board, revision: '7ee101da' }))
    act(() => useStatus.setState({ joins: 2 }))
    await flush()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(screen.getByText('7ee101da · nerves_system_okdo_c100 0.3.0')).toBeTruthy()
  })
})
