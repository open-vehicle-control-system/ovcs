import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useRecordings } from '../recordings.js'
import * as service from '../../services/recordings.js'

vi.mock('../../services/recordings.js')

const initial = useRecordings.getState()
const recording = { id: '20261115T090000Z_review', state: 'recording', parts: [] }
const stopped = { ...recording, state: 'stopped' }
const disk = { id: 'internal', state: 'mounted' }

// A promise the test settles when it chooses.
function deferred() {
  let resolve
  const promise = new Promise((settle) => {
    resolve = settle
  })
  return { promise, resolve }
}

describe('recordings store', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    useRecordings.setState(initial)
    vi.mocked(service.fetchDisks).mockResolvedValue([disk])
  })

  it('keeps an action busy until the lists are read again after it', async () => {
    useRecordings.setState({ recordings: [recording] })
    const reload = deferred()
    vi.mocked(service.stopRecording).mockResolvedValue({})
    vi.mocked(service.fetchRecordings).mockReturnValue(reload.promise)

    const stopping = useRecordings.getState().stop(recording.id)
    await vi.waitFor(() => expect(service.fetchRecordings).toHaveBeenCalled())

    expect(useRecordings.getState().busy).toBe(`stop:${recording.id}`)
    reload.resolve([stopped])
    await stopping
    expect(useRecordings.getState()).toMatchObject({ busy: null, recordings: [stopped] })
  })

  it('drops a list read before an action that answers after it', async () => {
    useRecordings.setState({ recordings: [recording] })
    const before = deferred()
    vi.mocked(service.fetchRecordings).mockReturnValueOnce(before.promise).mockResolvedValue([stopped])
    vi.mocked(service.stopRecording).mockResolvedValue({})

    const polling = useRecordings.getState().load()
    await useRecordings.getState().stop(recording.id)
    before.resolve([recording])
    await polling

    expect(useRecordings.getState().recordings).toEqual([stopped])
  })

  it('drops a list read while an action runs', async () => {
    useRecordings.setState({ recordings: [recording] })
    const stop = deferred()
    const during = deferred()
    vi.mocked(service.stopRecording).mockReturnValue(stop.promise)
    vi.mocked(service.fetchRecordings).mockReturnValueOnce(during.promise).mockResolvedValue([stopped])

    const stopping = useRecordings.getState().stop(recording.id)
    const polling = useRecordings.getState().load()
    stop.resolve({})
    await stopping
    during.resolve([recording])
    await polling

    expect(useRecordings.getState().recordings).toEqual([stopped])
  })

  it('drops a refresh read before an action that answers after it', async () => {
    useRecordings.setState({ recordings: [recording] })
    const before = deferred()
    vi.mocked(service.fetchRecording).mockReturnValue(before.promise)
    vi.mocked(service.fetchRecordings).mockResolvedValue([stopped])
    vi.mocked(service.stopRecording).mockResolvedValue({})

    const polling = useRecordings.getState().refresh()
    await useRecordings.getState().stop(recording.id)
    before.resolve({ ...recording, bytes: 1000 })
    await polling

    expect(useRecordings.getState().recordings).toEqual([stopped])
  })

  it('drops the failure of a read made stale by an action', async () => {
    const before = deferred()
    vi.mocked(service.fetchRecordings).mockReturnValueOnce(before.promise).mockResolvedValue([stopped])
    vi.mocked(service.stopRecording).mockResolvedValue({})

    const polling = useRecordings.getState().load()
    await useRecordings.getState().stop(recording.id)
    before.resolve(Promise.reject(new Error('The vision unit did not answer in time')))
    await polling

    expect(useRecordings.getState().loadError).toBeNull()
  })
})
