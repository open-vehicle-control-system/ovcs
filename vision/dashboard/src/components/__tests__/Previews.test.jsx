import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, act, fireEvent } from '@testing-library/react'
import Previews from '../Previews.jsx'
import { useExporters } from '../../stores/exporters.js'

const socket = { channel: vi.fn(() => ({ on: vi.fn(), join: vi.fn(), push: vi.fn(() => ({ receive() { return this } })), off: vi.fn(), leave: vi.fn() })) }

const snapshot = {
  cameras: {
    left: { present: true, fps: 29.6, exposureTimeUs: 8000, analogueGain: 2.0, issues: [] },
    right: { present: false }
  },
  sync: { present: true, offsetMedianMs: 0.12, offsetMaxMs: 0.4, pairs: 150 },
  pair: {
    timing: { level: 'ok', camera: null, issues: [], later: 'right', offsetMs: 0.12, maxOffsetMs: 0.4, pairs: 150 },
    rows: { level: 'off', camera: null, issues: [] },
    focus: { level: 'warning', camera: 'right', issues: ['focus_mismatch'], softer: 'right', differencePercent: 30, left: 0.0312, right: 0.0218 },
    brightness: { level: 'ok', camera: null, issues: [], gauge: -0.3, brighter: 'left', differencePercent: 6, left: 104.2, right: 98.3 }
  },
  depth: {
    rate: { level: 'ok', camera: null, issues: [], gauge: 0.2, droppedPercent: 1.0, depthHz: 12.8, cameraHz: 12.9, loadPercent: 97.0 },
    range: { level: 'off', camera: null, issues: [] }
  },
  depthHz: 12.8,
  quality: { matchedPercent: 61.6, meanDisparityPx: 18.43, spreadPx: 6.08, jitterPx: 0.318 }
}

// A socket whose channels keep their handlers, so a test can push to them. Like the unit, the depth stream pushes
// `depthRange` as it joins, before anything bound later could hear it.
function liveSocket({ depthRange = null } = {}) {
  const handlers = {}
  const deliver = (topic, event, payload) => handlers[`${topic}/${event}`]?.(payload)
  const socket = {
    channel: vi.fn((topic) => ({
      on: vi.fn((event, handler) => { handlers[`${topic}/${event}`] = handler }),
      join: vi.fn(() => {
        if (topic === 'preview:depth' && depthRange !== null) deliver(topic, 'depth_range', { metres: depthRange })
        return { receive() { return this } }
      }),
      push: vi.fn(() => ({ receive() { return this } })),
      off: vi.fn(),
      leave: vi.fn()
    }))
  }
  return { socket, push: (topic, event, payload) => act(() => handlers[`${topic}/${event}`](payload)) }
}

describe('Previews', () => {
  const card = (id) => document.querySelector(`[data-card="${id}"]`)
  const figure = (stream) => screen.getByText(stream, { selector: 'figcaption span' }).closest('figure')

  it("puts each camera's rate and exposure under its own preview", () => {
    render(<Previews status={snapshot} socket={socket} />)

    expect(figure('left').contains(card('left'))).toBe(true)
    const shown = (id, label) => card(id).querySelector(`[data-figure="${label}"]`).textContent
    expect(shown('left', 'rate')).toBe('rate29.6 fps')
    expect(shown('left', 'exposure')).toBe('exposure8.0 ms')
    expect(shown('left', 'gain')).toBe('gain2.0')
    expect(card('left').querySelector('[data-figure="rate"] .ovcs-status--ok')).not.toBeNull()
    expect(figure('right').contains(card('right'))).toBe(true)
    expect(card('right').textContent).toContain('absent')
  })

  it("puts the cameras' timing, rows, focus and brightness between the two camera previews", () => {
    render(<Previews status={snapshot} socket={socket} />)

    const pair = screen.getByRole('list', { name: 'Camera pair' })
    const row = [...pair.parentElement.children]
    expect(row).toEqual([figure('left'), pair, figure('right')])
    for (const id of ['timing', 'rows', 'focus', 'brightness']) expect(pair.contains(card(id))).toBe(true)
    expect(card('timing').textContent).toContain('0.12 ms')
    expect(card('brightness').textContent).toContain('left brighter')
  })

  it("badges the frame of a camera with something to do, and rings it, its text and layout unchanged", () => {
    const right = { present: true, fps: 29.6, issues: ['focus_mismatch', 'large_row_correction', 'uneven_rows'] }
    render(<Previews status={{ ...snapshot, cameras: { ...snapshot.cameras, right } }} socket={socket} />)

    const badges = [...figure('right').querySelectorAll('[data-badge]')]
    expect(badges.map((badge) => badge.textContent)).toEqual(['Refocus', 'Recalibrate'])
    expect(badges[0].title).toContain('Softer than the other camera: refocus it')
    expect(figure('right').querySelector('[data-alert]')).not.toBeNull()
    expect(figure('left').querySelector('[data-badge]')).toBeNull()
    expect(figure('left').querySelector('[data-alert]')).toBeNull()
  })

  it('badges and rings the depth with what to do about it', () => {
    const depth = {
      rate: { level: 'warning', camera: null, issues: ['pairs_dropped'], droppedPercent: 14.2, depthHz: 30.0, cameraHz: 35.0 },
      range: { level: 'warning', camera: null, issues: ['too_near'], nearPercent: 31.4, nearestM: 1.39 }
    }
    render(<Previews status={{ ...snapshot, depth }} socket={socket} />)

    const badges = [...figure('depth').querySelectorAll('[data-badge]')]
    expect(badges.map((badge) => badge.textContent)).toEqual(['Lower frame rate', 'Too near'])
    expect(figure('depth').querySelector('[data-alert]')).not.toBeNull()

    const shown = (label) => card('depth').querySelector(`[data-figure="${label}"]`).textContent
    expect(shown('dropped')).toContain('14 %, unhealthy')
    expect(shown('too near')).toContain('31 % < 1.4 m, unhealthy')
  })

  it('leaves out a depth check with nothing to judge, and badges nothing while the depth is healthy', () => {
    render(<Previews status={snapshot} socket={socket} />)

    expect(figure('depth').querySelector('[data-badge]')).toBeNull()
    expect(figure('depth').querySelector('[data-alert]')).toBeNull()
    expect(card('depth').querySelector('[data-figure="dropped"]').textContent).toBe('dropped1 %')
    expect(card('depth').querySelector('[data-figure="too near"]')).toBeNull()
  })

  it('puts the depth rate under the depth preview', () => {
    render(<Previews status={snapshot} socket={socket} />)

    expect(figure('depth').contains(card('depth'))).toBe(true)
    expect(card('depth').textContent).toContain('12.8 Hz')
  })

  it("puts the depth's quality under the depth preview", () => {
    render(<Previews status={snapshot} socket={socket} />)

    const shown = (label) => card('depth').querySelector(`[data-figure="${label}"]`).textContent
    expect(shown('matched')).toBe('matched62 %')
    expect(shown('disparity')).toBe('disparity18.4 ± 6.1 px')
    expect(shown('jitter')).toBe('jitter0.32 px')
    for (const title of ['Depth rate', 'Matched pixels', 'Disparity', 'Jitter']) {
      expect(screen.getByRole('button', { name: `About ${title}` })).toBeTruthy()
    }
  })

  it('shows the depth rate alone before the first quality', () => {
    render(<Previews status={{ ...snapshot, quality: null }} socket={socket} />)

    expect(card('depth').textContent).not.toContain('matched')
  })

  it('shows the previews before the first status', () => {
    render(<Previews status={null} socket={socket} />)

    expect(screen.getAllByRole('figure')).toHaveLength(3)
    expect(card('left')).toBeNull()
    expect(card('depth').querySelector('[data-figure="rate"]')).toBeNull()
    for (const id of ['timing', 'rows', 'focus', 'brightness']) expect(card(id).textContent).toContain('–')
  })

  describe('colour range', () => {
    const scale = () => card('depth').querySelector('[data-figure="colour scale"]')

    it('shows the range the depth stream pushes as it joins, then each one pushed after a rejoin or a change', () => {
      const { socket, push } = liveSocket({ depthRange: 8 })
      render(<Previews status={snapshot} socket={socket} />)
      expect(scale().textContent).toContain('8.0 m')

      // phoenix.js rejoins on the same channel, as after the unit restarted, and the unit pushes its range again.
      push('preview:depth', 'depth_range', { metres: 12 })
      expect(scale().textContent).toContain('12.0 m')

      push('preview:depth', 'depth_range', { metres: 0 })
      expect(scale().textContent).toContain('∞')
    })
  })

  describe('cameras of their own', () => {
    const listed = (...outputs) =>
      useExporters.setState({ exporters: [{ id: 'api', name: 'API', outputs: outputs.map((name) => ({ name, maxHz: 5 })) }] })
    afterEach(() => act(() => useExporters.setState({ exporters: [] })))

    it('shows a preview titled by its name for each camera_frame output beside the stereo pair', () => {
      listed('camera_frame:left', 'camera_frame:right', 'stereo_pair', 'camera_frame:hq', 'camera_frame:usb', 'detections')
      const { socket } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)

      const topics = socket.channel.mock.calls.map(([topic]) => topic).filter((topic) => topic.startsWith('preview:'))
      expect(topics.sort()).toEqual(['preview:depth', 'preview:hq', 'preview:left', 'preview:right', 'preview:usb'])
      expect(figure('hq')).not.toBeNull()
      expect(figure('usb')).not.toBeNull()
    })

    it("puts a camera of its own's rate, exposure and gain under its preview, nothing while the status has none", () => {
      listed('camera_frame:left', 'camera_frame:right', 'camera_frame:hq', 'camera_frame:usb')
      const hq = { present: true, fps: 9.8, exposureTimeUs: 12000, analogueGain: 4.0 }
      const { socket } = liveSocket()
      render(<Previews status={{ ...snapshot, cameras: { ...snapshot.cameras, hq } }} socket={socket} />)

      const shown = (label) => card('hq').querySelector(`[data-figure="${label}"]`).textContent
      expect(figure('hq').contains(card('hq'))).toBe(true)
      expect(shown('rate')).toBe('rate9.8 fps')
      expect(shown('exposure')).toBe('exposure12.0 ms')
      expect(shown('gain')).toBe('gain4.0')
      expect(card('usb')).toBeNull()
    })

    it('shows none without a camera of its own, the depth alone filling the row below the pair', () => {
      listed('camera_frame:left', 'camera_frame:right', 'stereo_pair')
      const { socket } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)

      expect(document.querySelectorAll('figure')).toHaveLength(3)
      const row = document.querySelector('[data-cameras]')
      expect(row.children).toHaveLength(1)
      expect(row.firstElementChild.contains(figure('depth'))).toBe(true)
      expect(row.className).toContain('lg:grid-rows-[minmax(0,1fr)]')
    })
  })

  describe('detections', () => {
    const listed = (...outputs) =>
      useExporters.setState({ exporters: [{ id: 'api', name: 'API', outputs: outputs.map((name) => ({ name, maxHz: 5 })) }] })
    afterEach(() => act(() => useExporters.setState({ exporters: [] })))

    const person = {
      label: 'person',
      score: 0.62,
      distanceM: 1.84,
      outline: [[0.25, 0.2], [0.75, 0.2], [0.75, 0.8], [0.25, 0.8]]
    }

    function showLeftFrame(push) {
      URL.createObjectURL = vi.fn(() => 'blob:left')
      URL.revokeObjectURL = vi.fn()
      push('preview:left', 'frame', new Uint8Array([1]).buffer)
      const image = screen.getByRole('img', { name: 'left preview' })
      Object.defineProperties(image, { naturalWidth: { value: 480 }, naturalHeight: { value: 270 } })
      fireEvent.load(image)
    }

    it("labels an object above its outline's top-left, whichever vertex comes first", () => {
      listed('detections')
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showLeftFrame(push)
      const turned = { ...person, outline: [[0.75, 0.8], [0.25, 0.8], [0.25, 0.2], [0.75, 0.2]] }

      push('detections', 'detections', { detections: [turned] })

      const label = figure('left').querySelector('svg[data-detections] text')
      expect([label.getAttribute('x'), label.getAttribute('y')]).toEqual(['123', '50'])
    })

    it('counts the objects under the left preview, once detection answers', () => {
      listed('detections')
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      expect(card('left').querySelector('[data-figure="objects"]')).toBeNull()

      push('detections', 'detections', { detections: [person] })

      expect(card('left').querySelector('[data-figure="objects"]').textContent).toBe('objects1')
      expect(screen.getByRole('button', { name: 'About Objects' })).toBeTruthy()
    })

    it("draws each object's outline and its label with the distance over the left preview", () => {
      listed('detections')
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showLeftFrame(push)

      push('detections', 'detections', { detections: [person] })

      const overlay = figure('left').querySelector('svg[data-detections]')
      expect(overlay.getAttribute('viewBox')).toBe('0 0 480 270')
      expect(overlay.querySelector('polygon').getAttribute('points')).toBe('120,54 360,54 360,216 120,216')
      expect(overlay.querySelector('text').textContent).toBe('person 1.8\u00a0m')
      expect(screen.getByRole('img', { name: 'Detected: person at 1.8\u00a0m' })).toBe(overlay)

      push('detections', 'detections', { detections: [] })
      expect(figure('left').querySelectorAll('svg[data-detections] polygon')).toHaveLength(0)
      expect(figure('left').querySelector('svg[data-detections]').getAttribute('aria-hidden')).toBe('true')
    })

    describe('with named pipelines', () => {
      it("subscribes to each channel the API exporter lists, the default's and every named pipeline's", () => {
        listed('stereo_pair', 'detections', 'detections:road_signs', 'detections:lanes')
        const { socket } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)

        const topics = socket.channel.mock.calls.map(([topic]) => topic)
        expect(topics).toEqual(expect.arrayContaining(['detections', 'detections:road_signs', 'detections:lanes']))
      })

      it('joins no detections channel while the API exporter lists none', () => {
        const { socket } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)

        const topics = socket.channel.mock.calls.map(([topic]) => topic)
        expect(topics.filter((topic) => topic.startsWith('detections'))).toEqual([])
        expect(figure('left').querySelector('svg[data-detections]')).toBeNull()
      })

      it("joins only the named pipelines' channels on a unit without the default pipeline", () => {
        listed('stereo_pair', 'detections:road_signs')
        const { socket } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)

        const topics = socket.channel.mock.calls.map(([topic]) => topic)
        expect(topics.filter((topic) => topic.startsWith('detections'))).toEqual(['detections:road_signs'])
      })

      it('draws no overlay before any pipeline has answered', () => {
        listed('detections', 'detections:road_signs')
        const { socket, push } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)
        showLeftFrame(push)

        expect(figure('left').querySelector('svg[data-detections]')).toBeNull()
      })

      it("draws each pipeline's boxes on the left preview and counts all their objects", () => {
        listed('detections', 'detections:road_signs')
        const { socket, push } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)
        showLeftFrame(push)
        const stop = { ...person, label: 'stop' }

        push('detections', 'detections', { detections: [person] })
        push('detections:road_signs', 'detections', { detections: [stop, stop] })

        const overlays = [...figure('left').querySelectorAll('svg[data-detections]')]
        expect(overlays.map((overlay) => overlay.getAttribute('aria-label'))).toEqual([
          'Detected: person at 1.8 m',
          'Detected: stop at 1.8 m, stop at 1.8 m'
        ])
        expect(card('left').querySelector('[data-figure="objects"]').textContent).toBe('objects3')
      })

      it("keeps a named pipeline's objects off the default's overlay", () => {
        listed('detections', 'detections:road_signs')
        const { socket, push } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)
        showLeftFrame(push)

        push('detections:road_signs', 'detections', { detections: [person] })

        expect(figure('left').querySelectorAll('svg[data-detections]')).toHaveLength(1)
        expect(figure('left').querySelector('svg[data-detections]').getAttribute('aria-label')).toBe('Detected: person at 1.8 m')
        expect(card('left').querySelector('[data-figure="objects"]').textContent).toBe('objects1')
      })
    })
  })
})
