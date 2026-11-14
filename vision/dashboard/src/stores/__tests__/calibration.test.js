import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { selectedCalibration, selectedId, useCalibration } from '../calibration.js'
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
    onError: vi.fn((callback) => (handlers.error = callback)),
    leave: vi.fn()
  }
  return { channel, handlers, receivers }
}

const initial = { session: null, calibrations: {}, saved: {}, selected: null, error: null, busy: false, unavailable: false }
const fallback = { columns: 8, rows: 6, squareMm: 25 }

describe('calibration store', () => {
  beforeEach(() => useCalibration.setState(initial))
  afterEach(() => vi.unstubAllGlobals())

  it('joins calibration, takes the session and each calibration pushed, and leaves on unlisten', () => {
    const { channel, handlers } = fakeChannel()
    const socket = { channel: vi.fn(() => channel) }
    const unlisten = useCalibration.getState().listen(socket)
    expect(socket.channel).toHaveBeenCalledWith('calibration', {})

    handlers.session({ phase: 'idle', calibration: null })
    handlers.calibration({ id: 'stereo', kind: 'stereo', source: 'builtIn' })
    handlers.calibration({ id: 'center', kind: 'camera', source: 'none' })
    handlers.calibration({ id: 'stereo', kind: 'stereo', source: 'stored' })

    const state = useCalibration.getState()
    expect(state.session).toEqual({ phase: 'idle', calibration: null })
    expect(Object.keys(state.calibrations)).toEqual(['stereo', 'center'])
    expect(state.calibrations.stereo.source).toBe('stored')
    // The first calibration pushed is the one picked, until the user picks another.
    expect(selectedId(state)).toBe('stereo')
    expect(selectedCalibration(state).source).toBe('stored')

    unlisten()
    expect(channel.leave).toHaveBeenCalled()
  })

  it('works on the calibration picked, and on the one of a running session whatever the pick', () => {
    useCalibration.setState({
      calibrations: { stereo: { id: 'stereo' }, center: { id: 'center' } },
      selected: 'stereo'
    })

    useCalibration.getState().select('center')
    expect(selectedId(useCalibration.getState())).toBe('center')

    useCalibration.setState({ session: { phase: 'capturing', calibration: 'stereo' } })
    expect(selectedCalibration(useCalibration.getState())).toEqual({ id: 'stereo' })
  })

  it('forgets the session when it leaves the channel or the channel fails, so that a stale one opens nothing', () => {
    const { channel, handlers } = fakeChannel()
    const unlisten = useCalibration.getState().listen({ channel: () => channel })

    handlers.session({ phase: 'capturing', calibration: 'stereo' })
    handlers.error()
    expect(useCalibration.getState().session).toBeNull()

    handlers.session({ phase: 'solved', calibration: 'stereo' })
    unlisten()
    expect(useCalibration.getState().session).toBeNull()
  })

  it('falls back to the first calibration pushed when the one picked is none of the unit\'s', () => {
    useCalibration.setState({ selected: 'bogus' })
    expect(selectedCalibration(useCalibration.getState())).toBeNull()

    useCalibration.setState({ calibrations: { stereo: { id: 'stereo' }, center: { id: 'center' } } })
    expect(selectedId(useCalibration.getState())).toBe('stereo')
    expect(selectedCalibration(useCalibration.getState())).toEqual({ id: 'stereo' })

    useCalibration.getState().select('center')
    expect(selectedId(useCalibration.getState())).toBe('center')
  })

  it('stops rejoining when the unit has nothing to calibrate, and keeps rejoining otherwise', () => {
    const { channel, receivers } = fakeChannel()
    useCalibration.getState().listen({ channel: () => channel })

    receivers.error({ reason: 'unavailable' })
    expect(channel.leave).not.toHaveBeenCalled()
    expect(useCalibration.getState().unavailable).toBe(false)

    receivers.error({ reason: 'nothing to calibrate' })
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

    useCalibration.setState({ calibrations: { center: { id: 'center' } }, selected: 'center' })

    await useCalibration.getState().start(fallback)

    const [url, options] = fetch.mock.calls[0]
    expect(url).toMatch(/\/api\/calibration-sessions$/)
    expect(JSON.parse(options.body)).toEqual({
      data: {
        type: 'calibration-sessions',
        attributes: { board: fallback },
        relationships: { calibration: { data: { type: 'calibrations', id: 'center' } } }
      }
    })

    await useCalibration.getState().reset()
    expect(fetch.mock.calls[1][0]).toMatch(/\/api\/calibration-resets$/)
    expect(JSON.parse(fetch.mock.calls[1][1].body)).toEqual({
      data: { type: 'calibration-resets', relationships: { calibration: { data: { type: 'calibrations', id: 'center' } } } }
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

  describe('the calibrations kept', () => {
    const resource = (id, attributes) => ({ type: 'saved-calibrations', id, attributes })
    const answer = (status, document) => ({ ok: status < 400, status, json: async () => document, text: async () => JSON.stringify(document ?? '') })

    it('reads the list of the calibration picked, of the first one pushed, and again at each change the channel announces', async () => {
      const fetch = vi.fn(async () => answer(200, { data: [resource('7', { name: 'Bench', inForce: true })] }))
      vi.stubGlobal('fetch', fetch)
      const { channel, handlers } = fakeChannel()
      useCalibration.getState().listen({ channel: vi.fn(() => channel) })

      handlers.calibration({ id: 'stereo', kind: 'stereo', source: 'stored' })
      await vi.waitFor(() => expect(useCalibration.getState().saved.stereo).toEqual([{ id: '7', name: 'Bench', inForce: true }]))
      expect(fetch.mock.calls[0][0]).toMatch(/\/api\/saved-calibrations\?filter\[calibration\]=stereo$/)

      // Another push of a calibration whose list is known reads nothing; a change of its list does.
      handlers.calibration({ id: 'stereo', kind: 'stereo', source: 'builtIn' })
      expect(fetch).toHaveBeenCalledTimes(1)
      handlers.saved({ calibration: 'stereo' })
      await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))

      useCalibration.getState().select('center')
      await vi.waitFor(() => expect(fetch.mock.calls[2][0]).toMatch(/filter\[calibration\]=center$/))
    })

    it('keeps the list it had when the unit cannot be read', async () => {
      useCalibration.setState({ saved: { stereo: [{ id: '7' }] } })
      vi.stubGlobal('fetch', vi.fn(async () => answer(503, { errors: [{ detail: 'down' }] })))

      await useCalibration.getState().loadSaved('stereo')
      expect(useCalibration.getState().saved.stereo).toEqual([{ id: '7' }])
      expect(useCalibration.getState().error).toBeNull()
    })

    it('selects, renames and deletes over the API, and shows a refusal', async () => {
      const fetch = vi.fn(async (_url, { method }) => (method === 'DELETE' ? answer(409, { errors: [{ detail: 'the unit runs on this calibration' }] }) : answer(200, { data: resource('7', { name: 'Workshop' }) })))
      vi.stubGlobal('fetch', fetch)

      await useCalibration.getState().useSaved('7')
      const [selectUrl, select] = fetch.mock.calls[0]
      expect(selectUrl).toMatch(/\/api\/calibration-selections$/)
      expect(JSON.parse(select.body)).toEqual({
        data: { type: 'calibration-selections', relationships: { savedCalibration: { data: { type: 'saved-calibrations', id: '7' } } } }
      })

      await useCalibration.getState().renameSaved('7', 'Workshop')
      const [renameUrl, rename] = fetch.mock.calls[1]
      expect([renameUrl.endsWith('/api/saved-calibrations/7'), rename.method]).toEqual([true, 'PATCH'])
      expect(JSON.parse(rename.body)).toEqual({ data: { type: 'saved-calibrations', id: '7', attributes: { name: 'Workshop' } } })

      await useCalibration.getState().deleteSaved('7')
      expect(useCalibration.getState().error).toBe('the unit runs on this calibration')
    })
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
