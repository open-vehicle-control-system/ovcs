import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
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
})
