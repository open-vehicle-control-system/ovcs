import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { useCalibration } from '../calibration.js'
import { loadBoard, saveBoard } from '../../services/calibration.js'

function fakeChannel() {
  const handlers = {}
  const receivers = {}
  const join = {
    receive: vi.fn((status, callback) => {
      receivers[status] = callback
      return join
    })
  }
  const channel = {
    on: vi.fn((event, callback) => (handlers[event] = callback)),
    join: vi.fn(() => join),
    leave: vi.fn()
  }
  return { channel, handlers, receivers }
}

const initial = { session: null, inUse: null, error: null, busy: false, unavailable: false }
const fallback = { columns: 8, rows: 6, squareMm: 25 }

describe('calibration store', () => {
  beforeEach(() => useCalibration.setState(initial))
  afterEach(() => vi.unstubAllGlobals())

  it('joins calibration, takes session and in_use pushes, and leaves on unlisten', () => {
    const { channel, handlers } = fakeChannel()
    const socket = { channel: vi.fn(() => channel) }
    const unlisten = useCalibration.getState().listen(socket)
    expect(socket.channel).toHaveBeenCalledWith('calibration', {})

    handlers.session({ phase: 'capturing' })
    handlers.in_use({ source: 'builtIn' })
    expect(useCalibration.getState().session).toEqual({ phase: 'capturing' })
    expect(useCalibration.getState().inUse).toEqual({ source: 'builtIn' })

    unlisten()
    expect(channel.leave).toHaveBeenCalled()
  })

  it('stops rejoining when the unit has no stereo unit, and keeps rejoining otherwise', () => {
    const { channel, receivers } = fakeChannel()
    useCalibration.getState().listen({ channel: () => channel })

    receivers.error({ reason: 'unavailable' })
    expect(channel.leave).not.toHaveBeenCalled()
    expect(useCalibration.getState().unavailable).toBe(false)

    receivers.error({ reason: 'no stereo unit' })
    expect(channel.leave).toHaveBeenCalled()
    expect(useCalibration.getState().unavailable).toBe(true)
  })

  it('keeps the channel session when an apply answers after a newer push', async () => {
    const { channel, handlers } = fakeChannel()
    useCalibration.getState().listen({ channel: () => channel })
    let respond
    vi.stubGlobal(
      'fetch',
      vi.fn(() => new Promise((resolve) => (respond = resolve)))
    )

    const pending = useCalibration.getState().apply()
    handlers.session({ phase: 'idle' })
    respond({ ok: true, json: async () => ({ data: { attributes: { phase: 'applying' } } }) })
    await pending

    expect(useCalibration.getState().session.phase).toBe('idle')
  })

  it('posts an action body and leaves the session to the channel', async () => {
    const fetch = vi.fn(async () => ({ ok: true, json: async () => ({ data: { attributes: { phase: 'capturing' } } }) }))
    vi.stubGlobal('fetch', fetch)

    await useCalibration.getState().start(fallback)

    const [url, options] = fetch.mock.calls[0]
    expect(url).toMatch(/\/api\/calibration-sessions$/)
    expect(JSON.parse(options.body)).toEqual({
      data: { type: 'calibration-sessions', attributes: { board: fallback } }
    })
    expect(useCalibration.getState()).toMatchObject({ session: null, busy: false, error: null })
  })

  it("sets error to the API's detail and clears busy when an action fails", async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({
        ok: false,
        status: 409,
        json: async () => ({ errors: [{ detail: 'cannot cancel while applying' }] })
      }))
    )

    const pending = useCalibration.getState().cancel()
    expect(useCalibration.getState().busy).toBe(true)
    await pending

    expect(useCalibration.getState()).toMatchObject({ error: 'cannot cancel while applying', busy: false })
  })

  it('loadBoard falls back to the default when storage throws or holds junk', () => {
    vi.stubGlobal('localStorage', {
      getItem: () => {
        throw new Error('denied')
      }
    })
    expect(loadBoard()).toEqual(fallback)

    vi.stubGlobal('localStorage', { getItem: () => '{"columns":"x"}' })
    expect(loadBoard()).toEqual(fallback)
  })

  it('saves and reloads the board, and ignores a storage that throws on save', () => {
    const data = {}
    vi.stubGlobal('localStorage', { getItem: (k) => data[k] ?? null, setItem: (k, v) => (data[k] = v) })
    saveBoard({ columns: 9, rows: 7, squareMm: 30 })
    expect(loadBoard()).toEqual({ columns: 9, rows: 7, squareMm: 30 })

    vi.stubGlobal('localStorage', {
      setItem: () => {
        throw new Error('full')
      }
    })
    expect(() => saveBoard(fallback)).not.toThrow()
  })
})
