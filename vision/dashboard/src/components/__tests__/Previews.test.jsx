import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import { render, screen, act, fireEvent } from '@testing-library/react'
import Previews from '../Previews.jsx'
import { useExporters } from '../../stores/exporters.js'

const socket = { channel: vi.fn(() => ({ on: vi.fn(), join: vi.fn(), push: vi.fn(() => ({ receive() { return this } })), off: vi.fn(), onError: vi.fn(), leave: vi.fn() })) }

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

// A socket whose channels keep their handlers, so a test can push to them, and fail one as the unit stopping it does.
// Like the unit, the depth stream pushes `depthRange` as it joins, before anything bound later could hear it.
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
      onError: vi.fn((handler) => { handlers[`${topic}/error`] = handler }),
      leave: vi.fn()
    }))
  }
  return {
    socket,
    push: (topic, event, payload) => act(() => handlers[`${topic}/${event}`](payload)),
    fail: (topic) => act(() => handlers[`${topic}/error`]())
  }
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
    const scale = () => figure('depth').querySelector('[data-colour-scale]')

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
      expect(row.className.split(' ')).toContain('lg:grid-rows-[minmax(0,1fr)_auto_auto]')
    })
  })

  describe('asides', () => {
    const listed = (...outputs) => useExporters.setState({ exporters: [{ id: 'api', name: 'API', outputs }] })

    // jsdom lays nothing out: the row's observer reports each preview `width` × `height` px, `caption` px of it its caption's.
    let observers
    beforeEach(() => {
      observers = []
      vi.stubGlobal(
        'ResizeObserver',
        class {
          constructor(callback) {
            observers.push(callback)
          }
          observe() {}
          disconnect() {}
        }
      )
    })
    afterEach(() => {
      act(() => useExporters.setState({ exporters: [] }))
      vi.unstubAllGlobals()
      vi.restoreAllMocks()
    })
    function previewsSized(width, height, caption) {
      vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockImplementation(function () {
        return this.tagName === 'FIGURE' ? width : 0
      })
      vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockImplementation(function () {
        return { FIGURE: height, FIGCAPTION: caption }[this.tagName] ?? 0
      })
      act(() => observers.forEach((callback) => callback([])))
    }

    // A preview's aside: its last part, after its frame and caption.
    const aside = (stream) => {
      const last = figure(stream).lastElementChild
      return last.hasAttribute('data-aside') ? last : null
    }
    const classes = (element) => element.className.split(' ')
    const frameOf = (stream) => figure(stream).firstElementChild
    const captionOf = (stream) => figure(stream).querySelector('figcaption')

    function renderAll() {
      listed({ name: 'camera_frame:hq', maxHz: 5 }, { name: 'camera_frame:usb', maxHz: 5 }, { name: 'segmentation:road', maxHz: 5, source: 'hq' })
      const { socket, push } = liveSocket({ depthRange: 8 })
      render(<Previews status={snapshot} socket={socket} />)
      push('segmentation:road', 'classes', { labels: ['road', 'sky'], roadClasses: ['road'] })
    }

    it("puts the depth's colour scale in its aside, out of its figures", () => {
      const { socket } = liveSocket({ depthRange: 8 })
      render(<Previews status={snapshot} socket={socket} />)

      expect(aside('depth').querySelector('[data-colour-scale]').textContent).toContain('8.0 m')
      expect(card('depth').querySelector('[data-colour-scale]')).toBeNull()
    })

    it("puts a camera's segmentation legend in its aside", () => {
      listed({ name: 'camera_frame:hq', maxHz: 5 }, { name: 'segmentation:road', maxHz: 5, source: 'hq' })
      const { socket, push } = liveSocket({ depthRange: 8 })
      render(<Previews status={snapshot} socket={socket} />)

      push('segmentation:road', 'classes', { labels: ['road', 'sky'], roadClasses: ['road'] })

      expect(aside('hq').contains(screen.getByRole('list', { name: 'road classes' }))).toBe(true)
    })

    it('gives every preview an aside under its caption, empty with nothing to show, sized by the row it shares with its neighbours', () => {
      renderAll()
      // The frame beside a 14rem aside would be 319 px wide and 320 px tall.
      previewsSized(543, 400, 80)

      const streams = ['left', 'right', 'depth', 'hq', 'usb']
      for (const stream of streams) expect(aside(stream)).not.toBeNull()
      for (const stream of streams) expect(aside(stream).className).toBe(aside('depth').className)
      for (const stream of streams) expect(frameOf(stream).className).not.toContain('col-')
      for (const stream of ['left', 'right', 'usb']) expect(aside(stream).childElementCount).toBe(0)

      // Each preview spans its row's three tracks, frame, caption and aside, which size them across the row.
      const pair = screen.getByRole('list', { name: 'Camera pair' })
      expect(classes(pair.parentElement)).toEqual(expect.arrayContaining(['grid-rows-[auto_auto_1fr]', 'gap-y-0']))
      expect(classes(pair)).toEqual(expect.arrayContaining(['row-span-3', 'self-center']))
      for (const stream of ['left', 'right']) {
        expect(classes(figure(stream))).toEqual(expect.arrayContaining(['row-span-3', 'grid', 'grid-cols-[minmax(0,1fr)]', 'grid-rows-subgrid']))
      }
      const row = document.querySelector('[data-cameras]')
      expect(classes(row)).toEqual(expect.arrayContaining(['lg:grid-rows-[minmax(0,1fr)_auto_auto]', 'lg:gap-y-0']))
      for (const stream of ['depth', 'hq', 'usb']) {
        expect(figure(stream).parentElement).toBe(row)
        expect(classes(figure(stream))).toEqual(expect.arrayContaining(['lg:row-span-3', 'lg:grid', 'lg:grid-cols-[minmax(0,1fr)]', 'lg:grid-rows-subgrid']))
      }
    })

    it("puts the asides of the depth's row beside their frames, from lg, once the frame left is as wide as tall", () => {
      renderAll()
      previewsSized(544, 400, 80)

      const row = document.querySelector('[data-cameras]')
      for (const stream of ['depth', 'hq', 'usb']) {
        expect(classes(figure(stream))).toEqual(
          expect.arrayContaining(['lg:row-span-3', 'lg:grid', 'lg:grid-cols-[minmax(0,1fr)_14rem]', 'lg:grid-rows-subgrid'])
        )
        // The aside takes the frame's track, in a column as wide in every preview, empty or not; the caption spans both columns.
        expect(classes(aside(stream))).toEqual(expect.arrayContaining(['lg:col-start-2', 'lg:row-start-1']))
        expect(aside(stream).className).toBe(aside('depth').className)
        expect(classes(captionOf(stream))).toContain('col-span-full')
        expect(figure(stream).parentElement).toBe(row)
      }
      expect(aside('depth').querySelector('[data-colour-scale]')).not.toBeNull()
      expect(aside('hq').contains(screen.getByRole('list', { name: 'road classes' }))).toBe(true)
      expect(aside('usb').childElementCount).toBe(0)

      // The pair's row keeps its asides under the captions, where they take the height the pair's checks add.
      for (const stream of ['left', 'right']) {
        expect(classes(figure(stream))).toEqual(expect.arrayContaining(['grid-cols-[minmax(0,1fr)]']))
        expect(aside(stream).className).not.toContain('col-start')
      }

      previewsSized(544, 401, 80)
      expect(aside('depth').className).toBe(aside('left').className)
      expect(classes(figure('depth'))).toContain('lg:grid-cols-[minmax(0,1fr)]')
    })

    it('places the asides as the row mounts, before its observer reports', () => {
      previewsSized(544, 400, 80)
      renderAll()

      expect(classes(figure('depth'))).toContain('lg:grid-cols-[minmax(0,1fr)_14rem]')
    })

    it('keeps the asides under the captions without an observer to measure the previews', () => {
      vi.unstubAllGlobals()
      vi.stubGlobal('ResizeObserver', undefined)
      renderAll()

      expect(aside('hq').className).toBe(aside('left').className)
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

    function showFrame(push, stream) {
      URL.createObjectURL = vi.fn(() => `blob:${stream}`)
      URL.revokeObjectURL = vi.fn()
      push(`preview:${stream}`, 'frame', new Uint8Array([1]).buffer)
      const image = screen.getByRole('img', { name: `${stream} preview` })
      Object.defineProperties(image, { naturalWidth: { value: 480 }, naturalHeight: { value: 270 } })
      fireEvent.load(image)
    }

    const showLeftFrame = (push) => showFrame(push, 'left')

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

    describe('on a camera of its own', () => {
      // The API names each pipeline's source: "left" for the stereo pair, a camera's name for its own.
      const listedWithSources = () =>
        useExporters.setState({
          exporters: [
            {
              id: 'api',
              name: 'API',
              outputs: [
                { name: 'camera_frame:left', maxHz: 5 },
                { name: 'camera_frame:hq', maxHz: 5 },
                { name: 'detections', maxHz: 5, source: 'left' },
                { name: 'detections:hq_people', maxHz: 5, source: 'hq' }
              ]
            }
          ]
        })

      const car = { label: 'car', score: 0.7, distanceM: null, outline: [[0.0, 0.0], [0.5, 0.0], [0.5, 0.5], [0.0, 0.5]] }

      it("draws a camera pipeline's boxes on that camera's preview, not the left one, joining each channel once", () => {
        listedWithSources()
        const { socket, push } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)
        showFrame(push, 'left')
        showFrame(push, 'hq')

        push('detections:hq_people', 'detections', { detections: [car, person] })
        push('detections', 'detections', { detections: [person] })

        const topics = socket.channel.mock.calls.map(([topic]) => topic).filter((topic) => topic.startsWith('detections'))
        expect(topics.sort()).toEqual(['detections', 'detections:hq_people'])
        expect(figure('hq').querySelectorAll('svg[data-detections]')).toHaveLength(1)
        expect(figure('hq').querySelectorAll('svg[data-detections] polygon')).toHaveLength(2)
        expect(figure('left').querySelectorAll('svg[data-detections] polygon')).toHaveLength(1)
        expect(card('hq').querySelector('[data-figure="objects"]').textContent).toBe('objects2')
        expect(card('left').querySelector('[data-figure="objects"]').textContent).toBe('objects1')
      })

      it('captions an object without a distance by its label alone', () => {
        listedWithSources()
        const { socket, push } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)
        showFrame(push, 'hq')

        push('detections:hq_people', 'detections', { detections: [car] })

        const overlay = figure('hq').querySelector('svg[data-detections]')
        expect(overlay.querySelector('text').textContent).toBe('car')
        expect(overlay.getAttribute('aria-label')).toBe('Detected: car')
      })

      it('draws a pipeline whose source the API does not name on the left preview', () => {
        listed('camera_frame:hq', 'detections:road_signs')
        const { socket, push } = liveSocket()
        render(<Previews status={snapshot} socket={socket} />)
        showFrame(push, 'left')
        showFrame(push, 'hq')

        push('detections:road_signs', 'detections', { detections: [person] })

        expect(figure('left').querySelectorAll('svg[data-detections]')).toHaveLength(1)
        expect(figure('hq').querySelector('svg[data-detections]')).toBeNull()
      })
    })
  })

  describe('segmentation', () => {
    const listed = (...outputs) => useExporters.setState({ exporters: [{ id: 'api', name: 'API', outputs }] })
    afterEach(() => act(() => useExporters.setState({ exporters: [] })))

    const outputs = [
      { name: 'camera_frame:left', maxHz: 5 },
      { name: 'camera_frame:hq', maxHz: 5 },
      { name: 'segmentation:road', maxHz: 5, source: 'hq' }
    ]

    // The channel's binary payload: eight little-endian 16-bit integers, then the label grid.
    function payload({ frame, band, grid, data }) {
      const buffer = new ArrayBuffer(16 + data.length)
      const view = new DataView(buffer)
      ;[...frame, ...band, ...grid].forEach((value, index) => view.setUint16(index * 2, value, true))
      new Uint8Array(buffer, 16).set(data)
      return buffer
    }

    // A 4 × 2 grid over the frame's bottom 960 × 480 band: road, road, sidewalk, car, then road and sky.
    const gridOf = (data) => payload({ frame: [960, 540], band: [0, 60, 960, 480], grid: [4, 2], data })
    const result = gridOf([0, 0, 1, 13, 0, 10, 10, 10])
    const cityscapes = ['road', 'sidewalk', 'building', 'wall', 'fence', 'pole', 'traffic_light', 'traffic_sign', 'vegetation',
      'terrain', 'sky', 'person', 'rider', 'car', 'truck', 'bus', 'train', 'motorcycle', 'bicycle']

    // jsdom has no 2D canvas: each canvas gets a context of its own, which keeps the images put on it.
    let contexts
    beforeEach(() => {
      contexts = new Map()
      vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation(function () {
        if (!contexts.has(this)) {
          contexts.set(this, {
            createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
            putImageData: vi.fn()
          })
        }
        return contexts.get(this)
      })
    })
    afterEach(() => vi.restoreAllMocks())

    function showFrame(push, stream) {
      URL.createObjectURL = vi.fn(() => `blob:${stream}`)
      URL.revokeObjectURL = vi.fn()
      push(`preview:${stream}`, 'frame', new Uint8Array([1]).buffer)
      const image = screen.getByRole('img', { name: `${stream} preview` })
      Object.defineProperties(image, { naturalWidth: { value: 480 }, naturalHeight: { value: 270 } })
      fireEvent.load(image)
    }

    const overlay = (name) => screen.getByRole('img', { name })
    const canvasOf = (svg) => svg.querySelector('canvas')
    const put = (svg) => contexts.get(canvasOf(svg)).putImageData.mock.lastCall[0]
    const pixel = (svg, index) => [...put(svg).data.slice(index * 4, index * 4 + 4)]
    const legend = (name = 'road') => screen.getByRole('list', { name: `${name} classes` })
    const items = (name) => [...legend(name).querySelectorAll('li')].map((item) => item.textContent)
    const present = (name = 'road') => [...legend(name).querySelectorAll('li[data-present]')].map((item) => item.dataset.class)
    // The legend's markup without its styling or presence: what decides its size.
    function shape(list) {
      const copy = list.cloneNode(true)
      for (const element of [copy, ...copy.querySelectorAll('*')]) {
        element.removeAttribute('class')
        element.removeAttribute('data-present')
      }
      return copy.outerHTML
    }
    // The channel the dashboard opened on `topic`.
    const channelOf = (socket, topic) => socket.channel.mock.results[socket.channel.mock.calls.findIndex(([called]) => called === topic)].value
    const acks = (socket, topic) => channelOf(socket, topic).push.mock.calls.filter(([event]) => event === 'ack').length

    it("joins a pipeline's channel for its camera's preview only", () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'left')
      showFrame(push, 'hq')

      push('segmentation:road', 'segmentation', result)

      const topics = socket.channel.mock.calls.map(([topic]) => topic).filter((topic) => topic.startsWith('segmentation'))
      expect(topics).toEqual(['segmentation:road'])
      expect(figure('hq').querySelector('[data-segmentation]')).not.toBeNull()
      expect(figure('left').querySelector('[data-segmentation]')).toBeNull()
    })

    it("stretches the label grid, a sharp pixel a cell, over the band of the camera's preview it covers", () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      push('segmentation:road', 'segmentation', result)

      // The frame's box, fitted in the preview as the object-contain image is: the smaller of the two scales.
      const box = figure('hq').querySelector('[data-segmentation]')
      expect([box.style.getPropertyValue('--frame-width'), box.style.getPropertyValue('--frame-height')]).toEqual(['480', '270'])
      expect(box.className.split(' ')).toEqual(
        expect.arrayContaining([
          'absolute',
          'inset-0',
          'm-auto',
          'w-[min(100cqw,100cqh*var(--frame-width)/var(--frame-height))]',
          'h-[min(100cqh,100cqw*var(--frame-height)/var(--frame-width))]'
        ])
      )
      expect(box.parentElement.className.split(' ')).toEqual(expect.arrayContaining(['absolute', 'inset-0', '[container-type:size]']))
      // The band, by its fractions of the 960 × 540 frame: from row 60 down, 480 rows.
      const canvas = canvasOf(box)
      expect([canvas.style.left, canvas.style.top, canvas.style.width, canvas.style.height]).toEqual(['0%', '11.111%', '100%', '88.889%'])
      expect([canvas.width, canvas.height]).toEqual([4, 2])
      expect(canvas.className.split(' ')).toEqual(['absolute', '[image-rendering:pixelated]'])
      expect(screen.getByRole('img', { name: 'Segmented: road, sidewalk, sky, car' })).toBe(box)
    })

    it("lies under the boxes of a detection pipeline on the same camera", () => {
      listed(...outputs, { name: 'detections:hq_people', maxHz: 5, source: 'hq' })
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('detections:hq_people', 'detections', { detections: [{ label: 'car', score: 0.7, distanceM: null, outline: [[0, 0], [0.5, 0], [0.5, 0.5], [0, 0.5]] }] })
      push('segmentation:road', 'segmentation', result)

      // Neither layer has a z-index: the later sibling paints over the earlier.
      const boxes = figure('hq').querySelector('svg[data-detections]')
      const grid = figure('hq').querySelector('[data-segmentation]').parentElement
      expect(grid.parentElement).toBe(boxes.parentElement)
      expect(grid.compareDocumentPosition(boxes) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
      expect(`${grid.className} ${boxes.getAttribute('class')}`).not.toMatch(/\bz-/)
    })

    it('acks a grid it cannot decode, and draws nothing for it', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'segmentation', new Uint8Array([4, 0, 2, 0]).buffer)

      expect(acks(socket, 'segmentation:road')).toBe(1)
      expect(figure('hq').querySelector('[data-segmentation]')).toBeNull()
      expect(screen.queryByRole('list', { name: 'road classes' })).toBeNull()
    })

    it('colours each class in the Cityscapes palette at 40 % opacity, the road at 60 %', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      push('segmentation:road', 'segmentation', result)

      const svg = figure('hq').querySelector('[data-segmentation]')
      expect([put(svg).width, put(svg).height]).toEqual([4, 2])
      expect(pixel(svg, 0)).toEqual([128, 64, 128, 153])
      expect(pixel(svg, 2)).toEqual([244, 35, 232, 102])
      expect(pixel(svg, 3)).toEqual([0, 0, 142, 102])
      expect(pixel(svg, 5)).toEqual([70, 130, 180, 102])
    })

    it('redraws each grid on the same canvas', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'segmentation', result)
      const canvas = canvasOf(figure('hq').querySelector('[data-segmentation]'))
      push('segmentation:road', 'segmentation', gridOf([10, 10, 10, 10, 10, 10, 10, 10]))

      const svg = figure('hq').querySelector('[data-segmentation]')
      expect(canvasOf(svg)).toBe(canvas)
      expect(contexts.get(canvas).putImageData).toHaveBeenCalledTimes(2)
      expect(pixel(svg, 0)).toEqual([70, 130, 180, 102])
    })

    it('highlights every class the pipeline counts as road', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road', 'sidewalk'] })
      push('segmentation:road', 'segmentation', result)

      expect(pixel(figure('hq').querySelector('[data-segmentation]'), 2)).toEqual([244, 35, 232, 153])
      expect([...legend().querySelectorAll('[data-road]')].map((item) => item.dataset.class)).toEqual(['road', 'sidewalk'])
    })

    it('lists every class the pipeline names under the preview, in class order, the present ones in full and the road in bold', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      push('segmentation:road', 'segmentation', result)

      expect(figure('hq').lastElementChild.contains(legend())).toBe(true)
      expect(items('road')).toEqual(cityscapes.map((name) => name.replaceAll('_', ' ')))
      expect(present()).toEqual(['road', 'sidewalk', 'sky', 'car'])
      const item = (name) => legend().querySelector(`[data-class="${name}"]`)
      expect(item('car').classList.contains('opacity-40')).toBe(false)
      expect(item('bus').classList.contains('opacity-40')).toBe(true)
      expect(item('road').hasAttribute('data-road')).toBe(true)
      expect(item('road').lastChild.classList.contains('font-semibold')).toBe(true)
      expect(item('car').hasAttribute('data-road')).toBe(false)
      expect(item('car').lastChild.classList.contains('font-semibold')).toBe(false)
    })

    it('keeps the bold of a road class while it is absent', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road', 'terrain'] })
      push('segmentation:road', 'segmentation', result)

      const terrain = legend().querySelector('[data-class="terrain"]')
      expect(terrain.hasAttribute('data-present')).toBe(false)
      expect(terrain.lastChild.classList.contains('font-semibold')).toBe(true)
    })

    it('shows a class present for a second after the last grid with it, by its styling alone', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      const now = vi.spyOn(Date, 'now')
      render(<Previews status={snapshot} socket={socket} />)
      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      const roadOnly = gridOf([0, 0, 0, 0, 0, 0, 0, 0])
      const many = gridOf([0, 1, 2, 5, 8, 10, 13, 11])

      now.mockReturnValue(10_000)
      push('segmentation:road', 'segmentation', result)
      const before = shape(legend())
      now.mockReturnValue(10_999)
      push('segmentation:road', 'segmentation', roadOnly)
      expect(present()).toEqual(['road', 'sidewalk', 'sky', 'car'])

      now.mockReturnValue(11_000)
      push('segmentation:road', 'segmentation', roadOnly)
      expect(present()).toEqual(['road'])
      expect(shape(legend())).toBe(before)

      now.mockReturnValue(11_100)
      push('segmentation:road', 'segmentation', many)
      expect(present()).toEqual(['road', 'sidewalk', 'building', 'pole', 'vegetation', 'sky', 'person', 'car'])
      expect(shape(legend())).toBe(before)
    })

    it("takes a pipeline's grid and legend off its camera's preview when its channel fails", () => {
      listed(...outputs)
      const { socket, push, fail } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')
      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      push('segmentation:road', 'segmentation', result)

      fail('segmentation:road')

      expect(figure('hq').querySelector('[data-segmentation]')).toBeNull()
      expect(screen.queryByRole('list', { name: 'road classes' })).toBeNull()
    })

    it('lists no class until the class names come', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'segmentation', result)

      expect(figure('hq').querySelector('[data-segmentation]')).not.toBeNull()
      expect(screen.queryByRole('list', { name: 'road classes' })).toBeNull()
      expect(figure('hq').querySelector('[data-class]')).toBeNull()
    })

    it('draws nothing before the first result, and lists every class absent', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })

      expect(figure('hq').querySelector('[data-segmentation]')).toBeNull()
      expect(items('road')).toHaveLength(cityscapes.length)
      expect(present()).toEqual([])
    })

    it('acks each grid once it is rendered, with or without a frame to draw it on, and nothing else', () => {
      listed(...outputs)
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      expect(acks(socket, 'segmentation:road')).toBe(0)

      push('segmentation:road', 'segmentation', result)
      expect(acks(socket, 'segmentation:road')).toBe(1)

      showFrame(push, 'hq')
      push('segmentation:road', 'segmentation', result)
      expect(acks(socket, 'segmentation:road')).toBe(2)
    })

    it("keeps two pipelines' grids, classes and legends apart, and another camera's off this preview", () => {
      listed(
        ...outputs,
        { name: 'camera_frame:usb', maxHz: 5 },
        { name: 'segmentation:lanes', maxHz: 5, source: 'hq' },
        { name: 'segmentation:far', maxHz: 5, source: 'usb' }
      )
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      showFrame(push, 'hq')

      push('segmentation:road', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      push('segmentation:lanes', 'classes', { labels: cityscapes, roadClasses: ['sidewalk'] })
      push('segmentation:far', 'classes', { labels: cityscapes, roadClasses: ['road'] })
      push('segmentation:road', 'segmentation', gridOf([0, 0, 0, 0, 13, 13, 13, 13]))
      push('segmentation:lanes', 'segmentation', gridOf([1, 1, 1, 1, 0, 0, 0, 0]))
      push('segmentation:far', 'segmentation', gridOf([10, 10, 10, 10, 10, 10, 10, 10]))

      const road = overlay('Segmented: road, car')
      const lanes = overlay('Segmented: road, sidewalk')
      expect([...figure('hq').querySelectorAll('[data-segmentation]')]).toEqual([road, lanes])
      expect([pixel(road, 0), pixel(road, 4)]).toEqual([[128, 64, 128, 153], [0, 0, 142, 102]])
      expect([pixel(lanes, 0), pixel(lanes, 4)]).toEqual([[244, 35, 232, 153], [128, 64, 128, 102]])
      expect(present('road')).toEqual(['road', 'car'])
      expect(present('lanes')).toEqual(['road', 'sidewalk'])
      expect([...legend('road').querySelectorAll('[data-road]')].map((item) => item.dataset.class)).toEqual(['road'])
      expect([...legend('lanes').querySelectorAll('[data-road]')].map((item) => item.dataset.class)).toEqual(['sidewalk'])
      expect(figure('hq').contains(legend('far'))).toBe(false)
      expect(figure('usb').contains(legend('far'))).toBe(true)
    })
  })
})
