import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  changeDisk,
  deleteRecording,
  ejectDisk,
  fetchDisks,
  fetchRecording,
  fetchRecordings,
  formatDisk,
  recordingDownloadUrl,
  startRecording,
  stopRecording
} from '../recordings.js'

const respond = (body, status = 200) => ({ ok: status < 400, status, json: async () => body })

const recording = {
  type: 'recordings',
  id: '20261115T090000Z_review',
  attributes: { name: '20261115T090000Z_review', state: 'stopped', preset: 'review', bytes: 2000 },
  relationships: {
    disk: { data: null },
    parts: {
      data: [
        { type: 'recording-parts', id: '20261115T090000Z_review' },
        { type: 'recording-parts', id: '20261115T090000Z_review_part2' }
      ]
    }
  }
}

const part = (id, number, disk) => ({
  type: 'recording-parts',
  id,
  attributes: { name: id, number, bytes: 1000 },
  relationships: { disk: { data: { type: 'disks', id: disk } } }
})

describe('recordings service', () => {
  let fetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  const sent = () => {
    const [url, init] = fetchMock.mock.calls[0]
    return { url, method: init.method, body: init.body === undefined ? undefined : JSON.parse(init.body) }
  }

  it('reads the recordings with their parts and the disk each is on', async () => {
    fetchMock.mockResolvedValue(
      respond({
        data: [recording],
        included: [part('20261115T090000Z_review', 1, 'stick'), part('20261115T090000Z_review_part2', 2, 'internal')]
      })
    )

    expect(await fetchRecordings()).toEqual([
      {
        id: '20261115T090000Z_review',
        name: '20261115T090000Z_review',
        state: 'stopped',
        preset: 'review',
        bytes: 2000,
        disk: null,
        parts: [
          { name: '20261115T090000Z_review', number: 1, bytes: 1000, disk: 'stick' },
          { name: '20261115T090000Z_review_part2', number: 2, bytes: 1000, disk: 'internal' }
        ]
      }
    ])
    expect(sent().url).toContain('/api/recordings?include=parts')
  })

  it('reads one recording, its disk in use', async () => {
    fetchMock.mockResolvedValue(
      respond({ data: { ...recording, relationships: { ...recording.relationships, disk: { data: { type: 'disks', id: 'stick' } } } }, included: [] })
    )

    expect(await fetchRecording('20261115T090000Z_review')).toMatchObject({ id: '20261115T090000Z_review', disk: 'stick' })
    expect(sent().url).toContain('/api/recordings/20261115T090000Z_review?include=parts')
  })

  it('starts a recording of a preset on a clock, and stops it', async () => {
    fetchMock.mockResolvedValue(respond({ data: recording, included: [] }, 201))
    await startRecording({ preset: 'replay', clock: 'since_start' })
    expect(sent()).toMatchObject({
      method: 'POST',
      body: { data: { type: 'recordings', attributes: { preset: 'replay', clock: 'since_start' } } }
    })

    fetchMock.mockClear()
    fetchMock.mockResolvedValue(respond({ data: recording }))
    await stopRecording('20261115T090000Z_review')
    expect(sent()).toMatchObject({
      method: 'PATCH',
      body: { data: { type: 'recordings', id: '20261115T090000Z_review', attributes: { state: 'stopped' } } }
    })
    expect(sent().url).toContain('/api/recordings/20261115T090000Z_review')
  })

  it('deletes a recording, and links to its download', async () => {
    fetchMock.mockResolvedValue({ ok: true, status: 204, json: async () => Promise.reject(new SyntaxError('empty')) })
    await deleteRecording('20261115T090000Z_review')
    expect(sent()).toMatchObject({ method: 'DELETE' })

    expect(recordingDownloadUrl('20261115T090000Z_review')).toMatch(/\/api\/recordings\/20261115T090000Z_review\/download$/)
  })

  it('reads the disks, and changes, ejects and formats one', async () => {
    fetchMock.mockResolvedValue(respond({ data: [{ type: 'disks', id: 'internal', attributes: { internal: true, position: 0 } }] }))
    expect(await fetchDisks()).toEqual([{ id: 'internal', internal: true, position: 0 }])

    fetchMock.mockClear()
    fetchMock.mockResolvedValue(respond({ data: { type: 'disks', id: 'stick', attributes: { position: 0 } } }))
    await changeDisk('stick', { position: 0 })
    expect(sent()).toMatchObject({ method: 'PATCH', body: { data: { type: 'disks', id: 'stick', attributes: { position: 0 } } } })

    fetchMock.mockClear()
    fetchMock.mockResolvedValue(respond({ data: { type: 'disk-ejects', id: '1' } }, 201))
    await ejectDisk('stick')
    expect(sent()).toMatchObject({
      method: 'POST',
      body: { data: { type: 'disk-ejects', relationships: { disk: { data: { type: 'disks', id: 'stick' } } } } }
    })

    fetchMock.mockClear()
    fetchMock.mockResolvedValue(respond({ data: { type: 'disk-formats', id: '2' } }, 201))
    await formatDisk('sdb1', 'ovcs-recordings')
    expect(sent()).toMatchObject({
      method: 'POST',
      body: {
        data: {
          type: 'disk-formats',
          attributes: { label: 'ovcs-recordings' },
          relationships: { disk: { data: { type: 'disks', id: 'sdb1' } } }
        }
      }
    })
  })
})
