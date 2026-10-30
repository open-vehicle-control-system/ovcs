import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  useParameters, orderedGroups, flowGroups, sideGroups, groupParameters, groupUnsaved
} from '../parameters.js'
import * as service from '../../services/parameters.js'

vi.mock('../../services/parameters.js')

const parameter = (id, group, extra = {}) => ({
  id, group, name: id, value: 12, saved: 12, state: 'builtin', controller: null, greaterThan: null, ...extra
})

const snapshot = (p1 = 12, unsaved = 0) => ({
  groups: [
    { id: 'side', name: 'Side', placement: 'side', position: 3, parameterIds: ['side.p'] },
    { id: 'stereo.match', name: 'Match', placement: 'flow', position: 2, parameterIds: ['stereo.match.p1', 'stereo.match.p2'] },
    { id: 'camera', name: 'Camera', placement: 'flow', position: 1, parameterIds: [] }
  ],
  parameters: {
    'stereo.match.p1': parameter('stereo.match.p1', 'stereo.match', { value: p1, saved: 12, state: p1 === 12 ? 'builtin' : 'unsaved' }),
    'stereo.match.p2': parameter('stereo.match.p2', 'stereo.match', { state: 'unsaved' }),
    'side.p': parameter('side.p', 'side')
  },
  unsaved
})

const initial = useParameters.getState()

describe('parameters store', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    useParameters.setState({ ...initial, editing: new Set() }, true)
  })
  afterEach(() => {
    useParameters.getState().stopPolling()
    vi.useRealTimers()
  })

  const state = () => useParameters.getState()

  it('loads groups, parameters and the unsaved count', async () => {
    service.fetchGroups.mockResolvedValue(snapshot(12, 1))

    await state().load()

    expect(state().groups).toHaveLength(3)
    expect(state().parameters['stereo.match.p1'].value).toBe(12)
    expect(state().unsaved).toBe(1)
  })

  it('keeps the value of a parameter being edited when a poll arrives', async () => {
    service.fetchGroups.mockResolvedValueOnce(snapshot(12))
    await state().load()
    state().beginEdit('stereo.match.p1')

    service.fetchGroups.mockResolvedValueOnce(snapshot(20))
    await state().load()

    expect(state().parameters['stereo.match.p1'].value).toBe(12)

    state().endEdit('stereo.match.p1')
    service.fetchGroups.mockResolvedValueOnce(snapshot(20))
    await state().load()
    expect(state().parameters['stereo.match.p1'].value).toBe(20)
  })

  it('does not let a poll overwrite a change in flight', async () => {
    service.fetchGroups.mockResolvedValue(snapshot(12))
    await state().load()
    let accept
    service.setParameter.mockReturnValue(new Promise((resolve) => { accept = resolve }))

    const pending = state().set('stereo.match.p1', 8)
    await state().load()
    expect(state().parameters['stereo.match.p1'].value).toBe(8)

    accept(parameter('stereo.match.p1', 'stereo.match', { value: 8, state: 'unsaved' }))
    await pending
    expect(state().parameters['stereo.match.p1'].state).toBe('unsaved')
  })

  it('applies a change at once, then the value the server answers', async () => {
    service.fetchGroups.mockResolvedValue(snapshot(12))
    await state().load()
    let accept
    service.setParameter.mockReturnValue(new Promise((resolve) => { accept = resolve }))

    const pending = state().set('stereo.match.p1', 8)
    expect(state().parameters['stereo.match.p1'].value).toBe(8)

    accept(parameter('stereo.match.p1', 'stereo.match', { value: 9, state: 'unsaved' }))
    await pending
    expect(state().parameters['stereo.match.p1']).toMatchObject({ value: 9, state: 'unsaved' })
    expect(state().error).toBeNull()
  })

  it('restores the previous value and keeps the detail of a refused change', async () => {
    service.fetchGroups.mockResolvedValue(snapshot(12))
    await state().load()
    service.setParameter.mockRejectedValue(new Error('must be at most 15'))

    await state().set('stereo.match.p1', 99)

    expect(state().parameters['stereo.match.p1'].value).toBe(12)
    expect(state().error).toBe('must be at most 15')
  })

  it.each([
    ['save', 'saveParameters', []],
    ['discard', 'discardParameters', []],
    ['reset', 'resetParameters', [{ type: 'parameters', id: 'stereo.match.p1' }]]
  ])('reloads after %s', async (action, call, args) => {
    service[call].mockResolvedValue(['stereo.match.p1'])
    service.fetchGroups.mockResolvedValue(snapshot(12, 0))

    await state()[action](...args)

    expect(service[call]).toHaveBeenCalledWith(...args)
    expect(service.fetchGroups).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['save', 'saveParameters', []],
    ['discard', 'discardParameters', []],
    ['reset', 'resetParameters', [{ type: 'parameter-groups', id: 'stereo.match' }]]
  ])('reloads after a failed %s, which may have changed some values', async (action, call, args) => {
    service[call].mockRejectedValue(new Error('stereo.match.p1: owner is busy'))
    service.fetchGroups.mockResolvedValue(snapshot(12, 0))

    await state()[action](...args)

    expect(service.fetchGroups).toHaveBeenCalledTimes(1)
    expect(state().groups).toHaveLength(3)
    expect(state().error).toBe('stereo.match.p1: owner is busy')
  })

  it('keeps the error of a failed save and the unsaved count', async () => {
    service.fetchGroups.mockResolvedValue(snapshot(8, 3))
    await state().load()
    service.saveParameters.mockRejectedValue(new Error('database unavailable'))

    await state().save()

    expect(state().error).toBe('database unavailable')
    expect(state().unsaved).toBe(3)
  })

  it('clears an error that came from a load once a load succeeds', async () => {
    service.fetchGroups.mockRejectedValueOnce(new Error('GET failed: 500'))
    await state().load()
    expect(state().error).toBe('GET failed: 500')

    service.fetchGroups.mockResolvedValueOnce(snapshot())
    await state().load()
    expect(state().error).toBeNull()
  })

  it('keeps an error from an action when a load succeeds', async () => {
    service.saveParameters.mockRejectedValue(new Error('database unavailable'))
    service.fetchGroups.mockResolvedValue(snapshot())
    await state().save()

    await state().load()

    expect(state().error).toBe('database unavailable')
  })

  it('dismisses the error', async () => {
    service.saveParameters.mockRejectedValue(new Error('database unavailable'))
    await state().save()

    state().dismissError()

    expect(state().error).toBeNull()
  })

  it('drops a snapshot requested before a change completed, then reloads', async () => {
    service.fetchGroups.mockResolvedValueOnce(snapshot(12))
    await state().load()
    let finish
    service.fetchGroups.mockReturnValueOnce(new Promise((resolve) => { finish = resolve }))
    service.fetchGroups.mockResolvedValue(snapshot(8))
    const poll = state().load()
    service.setParameter.mockResolvedValue(parameter('stereo.match.p1', 'stereo.match', { value: 8, state: 'unsaved' }))

    await state().set('stereo.match.p1', 8)
    finish(snapshot(12))
    await poll

    expect(state().parameters['stereo.match.p1'].value).toBe(8)
    expect(service.fetchGroups).toHaveBeenCalledTimes(3)
  })

  it('reloads once more when an action asks for a load during one', async () => {
    let finish
    service.fetchGroups.mockReturnValueOnce(new Promise((resolve) => { finish = resolve }))
    service.fetchGroups.mockResolvedValue(snapshot(12, 0))
    service.discardParameters.mockResolvedValue([])
    const poll = state().load()
    let settled = false

    const discarding = state().discard().then(() => { settled = true })
    await Promise.resolve()
    await Promise.resolve()
    expect(service.fetchGroups).toHaveBeenCalledTimes(1)
    expect(settled).toBe(false)

    finish(snapshot(12, 5))
    await discarding
    await poll

    expect(service.fetchGroups).toHaveBeenCalledTimes(2)
    expect(state().unsaved).toBe(0)
  })

  it('settles an action only once the reload that reflects it has finished', async () => {
    let finishPoll
    let finishReload
    service.fetchGroups.mockReturnValueOnce(new Promise((resolve) => { finishPoll = resolve }))
    service.fetchGroups.mockReturnValueOnce(new Promise((resolve) => { finishReload = resolve }))
    service.saveParameters.mockResolvedValue(['stereo.match.p1'])
    state().load()
    let settled = false

    const saving = state().save().then(() => { settled = true })
    finishPoll(snapshot(8, 1))
    await vi.waitFor(() => expect(service.fetchGroups).toHaveBeenCalledTimes(2))
    expect(settled).toBe(false)

    finishReload(snapshot(12, 0))
    await saving
    expect(state().unsaved).toBe(0)
  })

  it('updates the unsaved count at once from the change of state', async () => {
    service.fetchGroups.mockResolvedValue(snapshot(12, 1))
    await state().load()

    service.setParameter.mockResolvedValue(parameter('stereo.match.p1', 'stereo.match', { value: 8, state: 'unsaved' }))
    await state().set('stereo.match.p1', 8)
    expect(state().unsaved).toBe(2)

    service.setParameter.mockResolvedValue(parameter('stereo.match.p1', 'stereo.match', { value: 12, state: 'builtin' }))
    await state().set('stereo.match.p1', 12)
    expect(state().unsaved).toBe(1)
  })

  it('keeps a parameter protected until overlapping changes all finish', async () => {
    service.fetchGroups.mockResolvedValue(snapshot(12))
    await state().load()
    const accept = []
    service.setParameter.mockImplementation(() => new Promise((resolve) => accept.push(resolve)))

    const first = state().set('stereo.match.p1', 5)
    const second = state().set('stereo.match.p1', 6)
    accept[0](parameter('stereo.match.p1', 'stereo.match', { value: 5, state: 'unsaved' }))
    await first
    await state().load()
    expect(state().parameters['stereo.match.p1'].value).toBe(5)

    accept[1](parameter('stereo.match.p1', 'stereo.match', { value: 6, state: 'unsaved' }))
    await second
  })

  it('returns the export snippet', async () => {
    service.fetchExport.mockResolvedValue('config :a')

    expect(await state().exportSnippet()).toBe('config :a')
  })

  it('records a failed load', async () => {
    service.fetchGroups.mockRejectedValue(new Error('GET failed: 500'))

    await state().load()

    expect(state().error).toBe('GET failed: 500')
  })

  describe('polling', () => {
    beforeEach(() => vi.useFakeTimers())

    it('loads now and every interval until stopped', async () => {
      service.fetchGroups.mockResolvedValue(snapshot())

      state().startPolling(1000)
      await vi.advanceTimersByTimeAsync(0)
      expect(service.fetchGroups).toHaveBeenCalledTimes(1)

      await vi.advanceTimersByTimeAsync(2000)
      expect(service.fetchGroups).toHaveBeenCalledTimes(3)

      state().stopPolling()
      await vi.advanceTimersByTimeAsync(5000)
      expect(service.fetchGroups).toHaveBeenCalledTimes(3)
    })

    it('never runs two loads at once', async () => {
      let finish
      service.fetchGroups.mockReturnValue(new Promise((resolve) => { finish = resolve }))

      state().startPolling(1000)
      await vi.advanceTimersByTimeAsync(3500)
      expect(service.fetchGroups).toHaveBeenCalledTimes(1)

      finish(snapshot())
      await vi.advanceTimersByTimeAsync(1000)
      expect(service.fetchGroups).toHaveBeenCalledTimes(2)
    })

    it('does not start a second timer when started twice', async () => {
      service.fetchGroups.mockResolvedValue(snapshot())

      state().startPolling(1000)
      state().startPolling(1000)
      await vi.advanceTimersByTimeAsync(1000)

      expect(service.fetchGroups).toHaveBeenCalledTimes(2)
    })
  })

  describe('selectors', () => {
    beforeEach(() => useParameters.setState({ ...snapshot(), selectedGroupId: null }))

    it('orders groups by position and splits them by placement', () => {
      expect(orderedGroups(state()).map((g) => g.id)).toEqual(['camera', 'stereo.match', 'side'])
      expect(flowGroups(state()).map((g) => g.id)).toEqual(['camera', 'stereo.match'])
      expect(sideGroups(state()).map((g) => g.id)).toEqual(['side'])
    })

    it('lists the parameters of a group and counts its unsaved ones', () => {
      expect(groupParameters(state(), 'stereo.match').map((p) => p.id)).toEqual(['stereo.match.p1', 'stereo.match.p2'])
      expect(groupParameters(state(), 'nope')).toEqual([])
      expect(groupUnsaved(state(), 'stereo.match')).toBe(1)
      expect(groupUnsaved(state(), 'side')).toBe(0)
    })

    it('selects a group', () => {
      state().select('stereo.match')
      expect(state().selectedGroupId).toBe('stereo.match')
    })
  })
})
