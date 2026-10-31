import { describe, it, expect, vi } from 'vitest'
import { render, screen, act, fireEvent } from '@testing-library/react'
import Previews from '../Previews.jsx'

const socket = { channel: vi.fn(() => ({ on: vi.fn(), join: vi.fn(), push: vi.fn(() => ({ receive() { return this } })), leave: vi.fn() })) }

const snapshot = {
  cameras: { left: { present: true, fps: 29.6, exposure_time_us: 8000, analogue_gain: 2.0 }, right: { present: false } },
  sync: { present: true, offset_median_ms: 0.12, offset_max_ms: 0.4, pairs: 150 },
  depth_hz: 12.8,
  quality: { matched_percent: 61.6, mean_disparity_px: 18.43, spread_px: 6.08, jitter_px: 0.318 }
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

  it('puts the sync, row alignment and sharpness between the two camera previews', () => {
    render(<Previews status={snapshot} socket={socket} />)

    const pair = screen.getByRole('list', { name: 'Camera pair' })
    const row = [...pair.parentElement.children]
    expect(row).toEqual([figure('left'), pair, figure('right')])
    for (const id of ['sync', 'alignment', 'sharpness']) expect(pair.contains(card(id))).toBe(true)
    expect(card('sync').textContent).toContain('0.12 ms')
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
    for (const id of ['sync', 'alignment', 'sharpness']) expect(card(id).textContent).toContain('–')
  })

  describe('detections', () => {
    // A socket whose channels keep their handlers, so a test can push to them.
    function liveSocket() {
      const handlers = {}
      const socket = {
        channel: vi.fn((topic) => ({
          on: vi.fn((event, handler) => { handlers[`${topic}/${event}`] = handler }),
          join: vi.fn(() => ({ receive() { return this } })),
          push: vi.fn(() => ({ receive() { return this } })),
          leave: vi.fn()
        }))
      }
      return { socket, push: (topic, event, payload) => act(() => handlers[`${topic}/${event}`](payload)) }
    }

    const person = {
      label: 'person',
      score: 0.62,
      distance_m: 1.84,
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

    it('counts the objects under the left preview, once detection answers', () => {
      const { socket, push } = liveSocket()
      render(<Previews status={snapshot} socket={socket} />)
      expect(card('left').querySelector('[data-figure="objects"]')).toBeNull()

      push('detections', 'detections', { detections: [person] })

      expect(card('left').querySelector('[data-figure="objects"]').textContent).toBe('objects1')
      expect(screen.getByRole('button', { name: 'About Objects' })).toBeTruthy()
    })

    it("draws each object's outline and its label with the distance over the left preview", () => {
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
  })
})
