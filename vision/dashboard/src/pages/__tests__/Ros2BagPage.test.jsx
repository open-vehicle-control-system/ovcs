import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, fireEvent, render, screen, within } from '@testing-library/react'
import Ros2BagPage from '../Ros2BagPage.jsx'
import { useRecordings } from '../../stores/recordings.js'
import { useStatus } from '../../stores/status.js'
import { formatShortTime } from '../../components/recordings/format.js'

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

let DISKS
const DEFAULT_DISKS = [
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

// The rows of the dropped messages by topic shown in `container`, `null` while they are hidden.
const droppedTopics = (container) => {
  const table = within(container).queryByRole('table', { name: 'Dropped by topic' })
  return table && within(table).getAllByRole('row').slice(1).map((row) => within(row).getAllByRole('cell').map((cell) => cell.textContent))
}

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
    DISKS = DEFAULT_DISKS
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  // The clock's explanation shown under its choices.
  const shownExplanation = (recorder) =>
    [...within(recorder).getByRole('group', { name: 'Clock' }).querySelectorAll('[data-explanation]')]
      .filter((line) => !line.hidden)
      .map((line) => line.textContent)

  describe('a new recording', () => {
    it('offers the presets as two choices, each with one line on what it records', async () => {
      render(<Ros2BagPage />)
      await settle()

      const recorder = screen.getByRole('region', { name: 'Recorder' })
      expect(within(recorder).getByRole('heading', { name: 'New recording' })).toBeTruthy()
      const presets = within(recorder).getByRole('group', { name: 'Preset' })
      const radios = within(presets).getAllByRole('radio')
      expect(radios.map((radio) => [radio.value, radio.checked])).toEqual([
        ['review', true],
        ['replay', false]
      ])
      const review = within(presets).getByRole('radio', { name: 'review' })
      expect(document.getElementById(review.getAttribute('aria-describedby')).textContent).toMatch(/depth, detections/)
    })

    it("offers the clocks side by side, with the chosen one's explanation under them", async () => {
      render(<Ros2BagPage />)
      await settle()

      const recorder = screen.getByRole('region', { name: 'Recorder' })
      const clocks = within(recorder).getByRole('group', { name: 'Clock' })
      expect(within(clocks).getAllByRole('radio').map((radio) => radio.value)).toEqual(['automatic', 'system', 'since_start'])
      expect(within(clocks).getByRole('radio', { name: 'automatic' }).checked).toBe(true)
      expect(shownExplanation(recorder)).toEqual([expect.stringMatching(/once NTP has set it/)])

      fireEvent.click(within(clocks).getByRole('radio', { name: 'since start' }))
      expect(shownExplanation(recorder)).toEqual([expect.stringMatching(/clock is not set/)])
      const sinceStart = within(clocks).getByRole('radio', { name: 'since start' })
      expect(document.getElementById(sinceStart.getAttribute('aria-describedby')).textContent).toMatch(/clock is not set/)
    })

    it('starts the preset and clock chosen', async () => {
      render(<Ros2BagPage />)
      await settle()

      const recorder = screen.getByRole('region', { name: 'Recorder' })
      fireEvent.click(within(recorder).getByRole('radio', { name: 'replay' }))
      fireEvent.click(within(recorder).getByRole('radio', { name: 'since start' }))
      fireEvent.click(within(recorder).getByRole('button', { name: 'Start' }))
      await settle()

      expect(writes()).toEqual([
        { path: 'recordings', method: 'POST', body: { data: { type: 'recordings', attributes: { preset: 'replay', clock: 'since_start' } } } }
      ])
    })

    it('says beside Start which disk it records on and the room it has', async () => {
      render(<Ros2BagPage />)
      await settle()

      const start = screen.getByRole('button', { name: 'Start' })
      expect(start.disabled).toBe(false)
      expect(document.getElementById(start.getAttribute('aria-describedby')).textContent).toBe('on ovcs-recordings · 48.0 GB free')
    })

    it('skips a disk turned off or without the free floor, as the unit does', async () => {
      DISKS = [
        disk(STICK, { label: 'ovcs-recordings', sizeBytes: 64e9, freeBytes: 0.5e9, position: 0, state: 'mounted' }),
        disk('other', { label: 'spare', sizeBytes: 64e9, freeBytes: 20e9, position: 1, state: 'mounted', enabled: false }),
        disk('internal', { internal: true, freeBytes: 30e9, position: 2, state: 'mounted' })
      ]
      render(<Ros2BagPage />)
      await settle()

      const start = screen.getByRole('button', { name: 'Start' })
      expect(document.getElementById(start.getAttribute('aria-describedby')).textContent).toBe("on Unit's storage · 30.0 GB free")
      expect(within(screen.getByRole('listitem', { name: "Unit's storage" })).getByText('next')).toBeTruthy()
      expect(within(screen.getByRole('listitem', { name: 'ovcs-recordings' })).queryByText('next')).toBeNull()
    })

    it('keeps Start off with the reason when no disk can take a recording', async () => {
      DISKS = [disk('internal', { internal: true, freeBytes: 30e9, position: 0, state: 'mounted', enabled: false })]
      render(<Ros2BagPage />)
      await settle()

      const start = screen.getByRole('button', { name: 'Start' })
      expect(start.disabled).toBe(true)
      expect(document.getElementById(start.getAttribute('aria-describedby')).textContent).toBe(
        'No disk to record on: none is mounted, turned on and with 1.0 GB free.'
      )
    })
  })

  describe('the recording in progress', () => {
    const live = '20261115T100000Z_replay'

    beforeEach(() => {
      listed = [
        recording(
          live,
          {
            state: 'recording',
            preset: 'replay',
            durationMs: 42_000,
            bytes: 812_000_000,
            dropped: [{ topic: '/tf', count: 4 }, { topic: '/stereo/left/image_raw', count: 96 }]
          },
          STICK,
          [[live, 1, STICK]]
        ),
        ...listed
      ]
    })

    it('shows its name, clock and disk, and its live figures', async () => {
      useStatus.setState({
        snapshot: { exporters: [{ id: 'ros2_bag', status: { level: 'warning', detail: 'Recording replay since 10:00:00 UTC; dropped /stereo/left/image_raw 2' } }] }
      })
      render(<Ros2BagPage />)
      await settle()

      const recorder = screen.getByRole('region', { name: 'Recorder' })
      expect(within(recorder).getByRole('heading', { name: 'Recording' })).toBeTruthy()
      expect(within(recorder).getByText(live)).toBeTruthy()
      expect(within(recorder).getByText('system clock · on ovcs-recordings')).toBeTruthy()
      const figures = Object.fromEntries(
        within(recorder)
          .getAllByRole('term')
          .map((term) => [term.textContent, term.nextElementSibling.textContent])
      )
      expect(figures).toEqual({
        duration: '42 s',
        size: '812.0 MB',
        'write rate': '19.3 MB/s',
        'left on disk': '≈ 40 min 31 s',
        dropped: '100 messages · 1.8 %by topic'
      })
      expect(within(recorder).queryByRole('button', { name: 'Start' })).toBeNull()
      expect(within(recorder).queryByText(/^Recording replay since/)).toBeNull()
      expect(within(screen.getByRole('listitem', { name: 'ovcs-recordings' })).getByText('recording')).toBeTruthy()
    })

    it('opens its drops by topic, which stay open as it goes on', async () => {
      render(<Ros2BagPage />)
      await settle()

      const recorder = screen.getByRole('region', { name: 'Recorder' })
      expect(droppedTopics(recorder)).toBeNull()
      fireEvent.click(within(recorder).getByRole('button', { name: 'by topic' }))
      expect(droppedTopics(recorder)).toEqual([
        ['/stereo/left/image_raw', '96'],
        ['/tf', '4']
      ])

      listed[0].resource.attributes.durationMs = 43_000
      await act(() => vi.advanceTimersByTimeAsync(1000))
      await settle()
      expect(within(recorder).getByText('43 s')).toBeTruthy()
      expect(droppedTopics(recorder)).toHaveLength(2)
    })

    it('stops it', async () => {
      render(<Ros2BagPage />)
      await settle()

      fireEvent.click(within(screen.getByRole('region', { name: 'Recorder' })).getByRole('button', { name: 'Stop' }))
      await settle()
      expect(writes()).toEqual([
        { path: `recordings/${live}`, method: 'PATCH', body: { data: { type: 'recordings', id: live, attributes: { state: 'stopped' } } } }
      ])
    })

    it('is marked in the recordings, without Download or Delete', async () => {
      render(<Ros2BagPage />)
      await settle()

      const row = screen.getByRole('row', { name: live })
      expect(within(row).getByText('recording')).toBeTruthy()
      expect(within(row).queryByRole('link')).toBeNull()
      expect(within(row).queryByRole('button', { name: /Delete/ })).toBeNull()
    })
  })

  describe('the disks', () => {
    it('sit beside the new recording in the Recorder, before the recordings, with the fill order behind a hint', async () => {
      render(<Ros2BagPage />)
      await settle()

      const recorder = screen.getByRole('region', { name: 'Recorder' })
      expect(within(recorder).getByRole('region', { name: 'Disks' })).toBeTruthy()
      const headings = screen.getAllByRole('heading').map((heading) => heading.textContent)
      expect(headings.filter((name) => ['New recording', 'Disks', 'Recordings'].includes(name))).toEqual(['New recording', 'Disks', 'Recordings'])
      expect(within(recorder).getByRole('button', { name: 'About Fill order' })).toBeTruthy()
      expect(within(recorder).queryByText(/^A recording goes on the first disk/)).toBeNull()
    })

    it('list each in fill order with its place, state and space', async () => {
      render(<Ros2BagPage />)
      await settle()

      const items = within(screen.getByRole('region', { name: 'Disks' })).getAllByRole('listitem')
      expect(items.map((item) => item.getAttribute('aria-label'))).toEqual(['ovcs-recordings', "Unit's storage", 'sdb1'])

      const [stick, internal, blank] = items
      expect(within(stick).getByText('1')).toBeTruthy()
      expect(within(stick).getByText('mounted')).toBeTruthy()
      expect(within(stick).getByText('next')).toBeTruthy()
      expect(within(stick).getByText('48.0 GB free of 64.0 GB')).toBeTruthy()
      expect(within(stick).getByText('f2fs · sda1')).toBeTruthy()
      const meter = within(stick).getByRole('meter', { name: 'Space used on ovcs-recordings' })
      expect(meter.getAttribute('aria-valuetext')).toBe('48.0 GB free of 64.0 GB')

      expect(within(internal).getByText('2')).toBeTruthy()
      expect(within(internal).getByText('30.0 GB free')).toBeTruthy()
      expect(within(internal).queryByRole('meter')).toBeNull()

      expect(within(blank).getByText('unusable')).toBeTruthy()
      expect(within(blank).getByText('no f2fs or ext4 filesystem')).toBeTruthy()
      expect(within(blank).queryByRole('switch')).toBeNull()
    })

    it('show a disk being formatted and a disk turned off', async () => {
      DISKS = [
        disk(STICK, { label: 'ovcs-recordings', filesystem: 'f2fs', sizeBytes: 64e9, freeBytes: 48e9, position: 0, state: 'mounted', enabled: false }),
        disk('sdb1', { device: 'sdb1', sizeBytes: 32e9, state: 'formatting' })
      ]
      render(<Ros2BagPage />)
      await settle()

      const stick = screen.getByRole('listitem', { name: 'ovcs-recordings' })
      expect(within(stick).getByText('off: recordings skip it')).toBeTruthy()
      expect(within(stick).getByRole('switch', { name: 'Record on ovcs-recordings' }).getAttribute('aria-checked')).toBe('false')
      const formatting = screen.getByRole('listitem', { name: 'sdb1' })
      expect(within(formatting).getByText('formatting')).toBeTruthy()
      expect(within(formatting).queryByRole('button', { name: /Format|Eject/ })).toBeNull()
    })

    it('say why recordings skip a disk under the free floor', async () => {
      DISKS = [disk(STICK, { label: 'ovcs-recordings', sizeBytes: 64e9, freeBytes: 0.6e9, position: 0, state: 'mounted' })]
      render(<Ros2BagPage />)
      await settle()

      const stick = screen.getByRole('listitem', { name: 'ovcs-recordings' })
      expect(within(stick).getByText('under 1.0 GB free: recordings skip it')).toBeTruthy()
      expect(within(stick).queryByText('next')).toBeNull()
    })

    it('show a disk as ejecting while its eject is under way', async () => {
      render(<Ros2BagPage />)
      await settle()
      let answerEject
      fetchMock.mockImplementationOnce(() => new Promise((resolve) => (answerEject = resolve)))

      fireEvent.click(screen.getByRole('button', { name: 'Eject ovcs-recordings' }))
      await flush()

      const stick = screen.getByRole('listitem', { name: 'ovcs-recordings' })
      expect(within(stick).getByText('ejecting')).toBeTruthy()
      expect(within(stick).getByRole('button', { name: 'Eject ovcs-recordings' }).textContent).toBe('Ejecting…')
      expect(within(stick).getByRole('switch').disabled).toBe(true)

      answerEject(answer({ data: { type: 'disk-ejects', id: '1', attributes: {} } }, 201))
      await settle()
      expect(within(screen.getByRole('listitem', { name: 'ovcs-recordings' })).getByText('mounted')).toBeTruthy()
    })

    it('move up or down and turn on or off', async () => {
      render(<Ros2BagPage />)
      await settle()

      const stick = screen.getByRole('listitem', { name: 'ovcs-recordings' })
      expect(within(stick).getByRole('button', { name: 'Move ovcs-recordings up' }).disabled).toBe(true)
      fireEvent.click(within(stick).getByRole('button', { name: 'Move ovcs-recordings down' }))
      await settle()
      fireEvent.click(within(screen.getByRole('listitem', { name: "Unit's storage" })).getByRole('switch', { name: "Record on Unit's storage" }))
      await settle()

      expect(writes()).toEqual([
        { path: `disks/${STICK}`, method: 'PATCH', body: { data: { type: 'disks', id: STICK, attributes: { position: 1 } } } },
        { path: 'disks/internal', method: 'PATCH', body: { data: { type: 'disks', id: 'internal', attributes: { enabled: false } } } }
      ])
    })

    it("show each disk's one action on its controls line: Eject on a mounted disk, none on the unit's storage", async () => {
      render(<Ros2BagPage />)
      await settle()

      const actions = (name) =>
        within(screen.getByRole('listitem', { name }))
          .queryAllByRole('button', { name: /^(Eject|Format) / })
          .map((button) => button.textContent)
      expect(screen.queryByRole('button', { name: /^More for/ })).toBeNull()
      expect(actions('ovcs-recordings')).toEqual(['Eject'])
      expect(actions("Unit's storage")).toEqual([])
      expect(actions('sdb1')).toEqual(['Format…'])

      fireEvent.click(screen.getByRole('button', { name: 'Eject ovcs-recordings' }))
      await settle()
      expect(writes()).toEqual([
        { path: 'disk-ejects', method: 'POST', body: { data: { type: 'disk-ejects', relationships: { disk: { data: { type: 'disks', id: STICK } } } } } }
      ])
    })

    it('offer Format on an ejected disk', async () => {
      DISKS = [disk(STICK, { label: 'ovcs-recordings', filesystem: 'f2fs', device: 'sda1', position: 0, state: 'ejected' })]
      render(<Ros2BagPage />)
      await settle()

      const stick = screen.getByRole('listitem', { name: 'ovcs-recordings' })
      expect(within(stick).getByRole('button', { name: 'Format ovcs-recordings' }).textContent).toBe('Format…')
      expect(within(stick).queryByRole('button', { name: 'Eject ovcs-recordings' })).toBeNull()
    })

    it('format a disk without a filesystem with the label given, once confirmed', async () => {
      render(<Ros2BagPage />)
      await settle()

      fireEvent.click(screen.getByRole('button', { name: 'Format sdb1' }))

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

    it('say when there is none', async () => {
      DISKS = []
      render(<Ros2BagPage />)
      await settle()

      expect(within(screen.getByRole('region', { name: 'Disks' })).getByText('No disk found.')).toBeTruthy()
    })
  })

  describe('the recordings', () => {
    it('are a table of their facts, the newest first', async () => {
      listed = [recording('20261115T100000Z_replay', { preset: 'replay', startedAt: '2026-11-15T10:00:00.000000Z' }), ...listed]
      render(<Ros2BagPage />)
      await settle()

      const table = within(screen.getByRole('region', { name: 'Recordings' })).getByRole('table', { name: 'Recordings' })
      expect(within(table).getAllByRole('columnheader').map((header) => header.textContent)).toEqual([
        'Name',
        'Started',
        'Duration',
        'Size',
        'Disks',
        'Dropped',
        'Actions'
      ])
      const rows = within(table).getAllByRole('row').slice(1)
      expect(rows.map((row) => row.getAttribute('aria-label'))).toEqual(['20261115T100000Z_replay', STOPPED])

      const row = screen.getByRole('row', { name: STOPPED })
      const cells = within(row).getAllByRole('cell').map((cell) => cell.textContent)
      expect(cells.slice(0, 6)).toEqual([
        STOPPED,
        formatShortTime('2026-11-15T09:00:00.000000Z'),
        '3 min 05 s',
        '3.4 MB',
        "2 parts · ovcs-recordings, Unit's storage",
        '4 · 0.1 %'
      ])
      expect(within(rows[0]).getAllByRole('cell')[5].textContent).toBe('none')
    })

    it('open the drops by topic in a row below', async () => {
      render(<Ros2BagPage />)
      await settle()

      const row = screen.getByRole('row', { name: STOPPED })
      const toggle = within(row).getByRole('button', { name: '4 messages · 0.1 % dropped, by topic' })
      expect(toggle.getAttribute('aria-expanded')).toBe('false')
      fireEvent.click(toggle)
      expect(toggle.getAttribute('aria-expanded')).toBe('true')
      const breakdown = document.getElementById(toggle.getAttribute('aria-controls'))
      expect(breakdown.closest('tr').previousElementSibling).toBe(row)
      expect(droppedTopics(breakdown.closest('tr'))).toEqual([['/tf', '4']])
    })

    it('download each and delete it once confirmed', async () => {
      render(<Ros2BagPage />)
      await settle()

      const row = screen.getByRole('row', { name: STOPPED })
      const download = within(row).getByRole('link', { name: `Download ${STOPPED}` })
      expect(download.getAttribute('href')).toMatch(new RegExp(`/api/recordings/${STOPPED}/download$`))
      expect(download.hasAttribute('download')).toBe(true)

      fireEvent.click(within(row).getByRole('button', { name: `Delete ${STOPPED}` }))
      const dialog = screen.getByRole('alertdialog')
      expect(dialog.textContent).toMatch(/2 parts/)
      fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' }))
      await settle()

      expect(writes()).toEqual([{ path: `recordings/${STOPPED}`, method: 'DELETE', body: undefined }])
    })

    it('are a list of cards on a narrow screen, each with its facts on one line', async () => {
      vi.stubGlobal('matchMedia', vi.fn(() => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() })))
      render(<Ros2BagPage />)
      await settle()

      expect(window.matchMedia).toHaveBeenCalledWith('(min-width: 768px)')
      const recordings = screen.getByRole('region', { name: 'Recordings' })
      expect(within(recordings).queryByRole('table', { name: 'Recordings' })).toBeNull()
      const item = within(recordings).getByRole('listitem', { name: STOPPED })
      expect(within(item).queryByText('review')).toBeNull()
      expect(
        within(item).getByText(`${formatShortTime('2026-11-15T09:00:00.000000Z')} · 3 min 05 s · 3.4 MB · 2 parts · ovcs-recordings, Unit's storage`)
      ).toBeTruthy()
      fireEvent.click(within(item).getByRole('button', { name: '4 messages · 0.1 % dropped, by topic' }))
      expect(droppedTopics(item)).toEqual([['/tf', '4']])
      expect(within(item).getByRole('link', { name: `Download ${STOPPED}` })).toBeTruthy()
      expect(within(item).getByRole('button', { name: `Delete ${STOPPED}` })).toBeTruthy()
    })

    it('say when there is none', async () => {
      listed = []
      render(<Ros2BagPage />)
      await settle()

      const recordings = screen.getByRole('region', { name: 'Recordings' })
      expect(within(recordings).getByText('No recording on the disks plugged in.')).toBeTruthy()
      expect(within(recordings).queryByRole('table')).toBeNull()
    })
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
