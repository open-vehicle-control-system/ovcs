import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, fireEvent, render, screen, within } from '@testing-library/react'
import Ros2BagPage from '../Ros2BagPage.jsx'
import { useRecordings } from '../../stores/recordings.js'
import { useStatus } from '../../stores/status.js'

const STICK = 'c8803634-2bd4-4a62-8a68-ad456f6a52ce'

const disk = (id, attributes) => ({
  type: 'disks',
  id,
  attributes: {
    internal: false,
    label: null,
    filesystem: null,
    device: null,
    sizeBytes: null,
    freeBytes: null,
    position: null,
    enabled: true,
    state: 'unplugged',
    problem: null,
    lastSeenAt: '2026-11-15T08:00:00Z',
    ...attributes
  }
})

const DISKS = [
  disk(STICK, { label: 'ovcs-recordings', filesystem: 'f2fs', device: 'sda1', sizeBytes: 64e9, freeBytes: 48e9, position: 0, state: 'mounted' }),
  disk('internal', { internal: true, freeBytes: 30e9, position: 1, state: 'mounted' }),
  disk('sdb1', { device: 'sdb1', sizeBytes: 32e9, state: 'unusable', problem: 'no f2fs or ext4 filesystem' })
]

const STOPPED = '20261115T090000Z_review'

const recording = (id, attributes, disk = null, parts = [[id, 1, 'internal']]) => ({
  resource: {
    type: 'recordings',
    id,
    attributes: {
      name: id,
      state: 'stopped',
      preset: 'review',
      clock: 'automatic',
      clockInUse: 'system',
      clockSynchronized: true,
      startedAt: '2026-11-15T09:00:00.000000Z',
      durationMs: 185_000,
      bytes: 3_400_000,
      messages: 5400,
      dropped: [],
      ...attributes
    },
    relationships: {
      disk: { data: disk && { type: 'disks', id: disk } },
      parts: { data: parts.map(([name]) => ({ type: 'recording-parts', id: name })) }
    }
  },
  parts: parts.map(([name, number, partDisk]) => ({
    type: 'recording-parts',
    id: name,
    attributes: { name, number, bytes: 1_700_000 },
    relationships: { disk: { data: { type: 'disks', id: partDisk } } }
  }))
})

const answer = (document, status = 200) => ({ ok: status < 400, status, json: async () => document })
const flush = () => act(() => Promise.resolve())
const settle = async () => {
  for (let i = 0; i < 6; i += 1) await flush()
}

describe('Ros2BagPage', () => {
  let fetchMock
  let listed

  // The unit as fetch answers it: `listed` recordings, the disks, and 201 or 204 to a write.
  const serve = () =>
    fetchMock.mockImplementation(async (url, init = {}) => {
      const path = new URL(url, 'http://unit').pathname.replace(/^.*\/api\//, '')
      const method = init.method ?? 'GET'
      if (method === 'GET' && path === 'recordings')
        return answer({ data: listed.map((one) => one.resource), included: listed.flatMap((one) => one.parts) })
      if (method === 'GET' && path.startsWith('recordings/')) {
        const one = listed.find((listedOne) => path === `recordings/${listedOne.resource.id}`)
        return answer({ data: one.resource, included: one.parts })
      }
      if (method === 'GET' && path === 'disks') return answer({ data: DISKS })
      if (method === 'DELETE') return { ok: true, status: 204, json: async () => Promise.reject(new SyntaxError('empty')) }
      return answer({ data: { type: 'answers', id: '1', attributes: {} } }, 201)
    })

  const writes = () =>
    fetchMock.mock.calls
      .filter(([, init]) => init?.method && init.method !== 'GET')
      .map(([url, init]) => ({ path: url.replace(/^.*\/api\//, ''), method: init.method, body: init.body && JSON.parse(init.body) }))

  beforeEach(() => {
    vi.useFakeTimers()
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    listed = [recording(STOPPED, { dropped: [{ topic: '/tf', count: 4 }] }, null, [[STOPPED, 1, STICK], [`${STOPPED}_part2`, 2, 'internal']])]
    serve()
    useRecordings.setState({ recordings: [], disks: [], loaded: false, loadError: null, busy: null, error: null })
    useStatus.setState({ snapshot: null })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('offers each preset and clock with what it does, and starts the ones chosen', async () => {
    render(<Ros2BagPage />)
    await settle()

    const recorder = screen.getByRole('region', { name: 'Recorder' })
    const review = within(recorder).getByRole('radio', { name: 'review' })
    expect(review.checked).toBe(true)
    expect(review.getAttribute('aria-describedby')).toBeTruthy()
    expect(document.getElementById(review.getAttribute('aria-describedby')).textContent).toMatch(/depth, detections/)
    expect(within(recorder).getByRole('radio', { name: 'automatic' }).checked).toBe(true)

    fireEvent.click(within(recorder).getByRole('radio', { name: 'replay' }))
    fireEvent.click(within(recorder).getByRole('radio', { name: 'since start' }))
    fireEvent.click(within(recorder).getByRole('button', { name: 'Start' }))
    await settle()

    expect(writes()).toEqual([
      { path: 'recordings', method: 'POST', body: { data: { type: 'recordings', attributes: { preset: 'replay', clock: 'since_start' } } } }
    ])
  })

  it('shows the recording in progress with its live figures and disk, and stops it', async () => {
    const live = '20261115T100000Z_replay'
    listed = [
      recording(live, { state: 'recording', preset: 'replay', durationMs: 42_000, bytes: 812_000_000, dropped: [{ topic: '/stereo/left/image_raw', count: 2 }] }, STICK, [[live, 1, STICK]]),
      ...listed
    ]
    useStatus.setState({
      snapshot: { exporters: [{ id: 'ros2_bag', status: { level: 'warning', detail: 'Recording replay since 10:00:00 UTC; dropped /stereo/left/image_raw 2' } }] }
    })
    render(<Ros2BagPage />)
    await settle()

    const recorder = screen.getByRole('region', { name: 'Recorder' })
    expect(within(recorder).getByText(live)).toBeTruthy()
    expect(within(recorder).getByText('42 s')).toBeTruthy()
    expect(within(recorder).getByText('812.0 MB')).toBeTruthy()
    expect(within(recorder).getByText('ovcs-recordings')).toBeTruthy()
    expect(within(recorder).getByText('2: /stereo/left/image_raw 2')).toBeTruthy()
    expect(within(recorder).queryByRole('button', { name: 'Start' })).toBeNull()
    expect(within(recorder).queryByText(/^Recording replay since/)).toBeNull()

    listed[0].resource.attributes.durationMs = 43_000
    await act(() => vi.advanceTimersByTimeAsync(1000))
    await settle()
    expect(within(recorder).getByText('43 s')).toBeTruthy()

    fireEvent.click(within(recorder).getByRole('button', { name: 'Stop' }))
    await settle()
    expect(writes()).toEqual([
      { path: `recordings/${live}`, method: 'PATCH', body: { data: { type: 'recordings', id: live, attributes: { state: 'stopped' } } } }
    ])
  })

  it("lists each recording's facts, parts and disks, downloads it and deletes it once confirmed", async () => {
    render(<Ros2BagPage />)
    await settle()

    const item = screen.getByRole('listitem', { name: STOPPED })
    expect(within(item).getByText('review')).toBeTruthy()
    expect(within(item).getByText('3 min 05 s')).toBeTruthy()
    expect(within(item).getByText('3.4 MB')).toBeTruthy()
    expect(within(item).getByText('4: /tf 4')).toBeTruthy()
    expect(within(item).getByText("1 on ovcs-recordings, 2 on Unit's storage")).toBeTruthy()

    const download = within(item).getByRole('link', { name: `Download ${STOPPED}` })
    expect(download.getAttribute('href')).toMatch(new RegExp(`/api/recordings/${STOPPED}/download$`))
    expect(download.hasAttribute('download')).toBe(true)

    fireEvent.click(within(item).getByRole('button', { name: `Delete ${STOPPED}` }))
    const dialog = screen.getByRole('alertdialog')
    expect(dialog.textContent).toMatch(/2 parts/)
    fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' }))
    await settle()

    expect(writes()).toEqual([{ path: `recordings/${STOPPED}`, method: 'DELETE', body: undefined }])
  })

  it('lists the disks in their order, with their state and free space, and changes them', async () => {
    render(<Ros2BagPage />)
    await settle()

    const disks = screen.getByRole('region', { name: 'Disks' })
    const items = within(disks).getAllByRole('listitem')
    expect(items.map((item) => item.getAttribute('aria-label'))).toEqual(['ovcs-recordings', "Unit's storage", 'sdb1'])

    const stick = items[0]
    expect(within(stick).getByText('mounted')).toBeTruthy()
    expect(within(stick).getByText('f2fs')).toBeTruthy()
    const meter = within(stick).getByRole('meter', { name: 'Space used on ovcs-recordings' })
    expect(meter.getAttribute('aria-valuetext')).toBe('48.0 GB free of 64.0 GB')
    expect(within(stick).getByRole('button', { name: 'Move ovcs-recordings up' }).disabled).toBe(true)

    fireEvent.click(within(stick).getByRole('button', { name: 'Move ovcs-recordings down' }))
    await settle()
    fireEvent.click(within(items[1]).getByRole('switch', { name: "Record on Unit's storage" }))
    await settle()
    fireEvent.click(within(stick).getByRole('button', { name: 'Eject ovcs-recordings' }))
    await settle()

    expect(within(items[1]).queryByRole('button', { name: /Eject/ })).toBeNull()
    expect(within(items[2]).getByText('unusable')).toBeTruthy()
    expect(within(items[2]).getByText('no f2fs or ext4 filesystem')).toBeTruthy()

    expect(writes()).toEqual([
      { path: `disks/${STICK}`, method: 'PATCH', body: { data: { type: 'disks', id: STICK, attributes: { position: 1 } } } },
      { path: 'disks/internal', method: 'PATCH', body: { data: { type: 'disks', id: 'internal', attributes: { enabled: false } } } },
      { path: 'disk-ejects', method: 'POST', body: { data: { type: 'disk-ejects', relationships: { disk: { data: { type: 'disks', id: STICK } } } } } }
    ])
  })

  it('formats a disk without a filesystem with the label given, once confirmed', async () => {
    render(<Ros2BagPage />)
    await settle()

    const blank = screen.getByRole('listitem', { name: 'sdb1' })
    fireEvent.click(within(blank).getByRole('button', { name: 'Format sdb1' }))

    const dialog = screen.getByRole('dialog', { name: 'Format sdb1?' })
    const label = within(dialog).getByRole('textbox', { name: 'Label' })
    expect(label.value).toBe('ovcs-recordings')
    fireEvent.change(label, { target: { value: 'drive-2' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Format' }))
    await settle()

    expect(writes()).toEqual([
      {
        path: 'disk-formats',
        method: 'POST',
        body: {
          data: { type: 'disk-formats', attributes: { label: 'drive-2' }, relationships: { disk: { data: { type: 'disks', id: 'sdb1' } } } }
        }
      }
    ])
  })

  it("shows an action's failure", async () => {
    render(<Ros2BagPage />)
    await settle()
    fetchMock.mockImplementationOnce(async () =>
      answer({ errors: [{ status: '409', detail: 'no disk is mounted, turned on and with 1000000000 bytes free' }] }, 409)
    )

    fireEvent.click(screen.getByRole('button', { name: 'Start' }))
    await settle()

    expect(screen.getByRole('alert').textContent).toMatch(/no disk is mounted/)
  })

  it("shows the exporter's warning, such as a recording stopped for want of a disk", async () => {
    useStatus.setState({
      snapshot: { exporters: [{ id: 'ros2_bag', status: { level: 'warning', detail: 'Stopped: no disk left (20261115T090000Z_review)' } }] }
    })
    render(<Ros2BagPage />)
    await settle()

    expect(within(screen.getByRole('region', { name: 'Recorder' })).getByText(/Stopped: no disk left/)).toBeTruthy()
  })
})
