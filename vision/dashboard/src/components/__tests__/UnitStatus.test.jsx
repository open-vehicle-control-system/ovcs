import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import UnitStatus from '../UnitStatus.jsx'
import Previews from '../Previews.jsx'

const socket = { channel: vi.fn(() => ({ on: vi.fn(), join: vi.fn(), push: vi.fn(() => ({ receive() { return this } })), off: vi.fn(), leave: vi.fn() })) }

const snapshot = {
  cameras: { left: { present: true, fps: 29.6, exposure_time_us: 8000, analogue_gain: 2.0 }, right: { present: false } },
  sync: { present: true, offset_median_ms: 0.12, offset_max_ms: 0.4, pairs: 150 },
  hailo: 'absent',
  depth_hz: 12.8,
  zenoh: 'disconnected',
  cpu_percent: 37.25,
  stereo_segment_percent: 81.5,
  alignment: { offset_rows: -1.43, band_offset_rows: [-1.9, -1.6, -1.2, -1.0] },
  sharpness: { left: 0.0312, right: 0.0218 }
}

describe('UnitStatus and the pair status', () => {
  const card = (id) => document.querySelector(`[data-card="${id}"]`)
  const show = (status) =>
    render(
      <>
        <UnitStatus status={status} />
        <Previews status={status} socket={socket} />
      </>
    )

  it('shows Hailo absent', () => {
    show(snapshot)

    expect(card('hailo').textContent).toContain('absent')
  })

  it('shows Zenoh in the top bar', () => {
    show(snapshot)

    expect(card('zenoh').textContent).toContain('disconnected')
  })

  it('shows the CPU usage, and the stereo stages\' busy time as the stereo load, explained by its hint', () => {
    show(snapshot)

    expect(card('cpu').textContent).toContain('37 %')
    expect(card('segment').textContent).toContain('Stereo load')
    expect(card('segment').textContent).not.toContain('GPU')
    expect(card('segment').textContent).toContain('82 %')
    expect(card('segment').querySelector('button').getAttribute('aria-label')).toBe('About Stereo load')
  })

  it('shows the row alignment, overall and from left to right', () => {
    show(snapshot)

    expect(card('alignment').textContent).toContain('-1.4 rows')
    expect(card('alignment').textContent).toContain('left to right -1.9 · -1.6 · -1.2 · -1.0')
    expect(card('alignment').querySelector('.ovcs-status--error')).not.toBeNull()
  })

  it('shows an alignment within half a row as healthy', () => {
    show({ ...snapshot, alignment: { offset_rows: 0.2, band_offset_rows: [0.1, 0.2, 0.2, 0.3] } })

    expect(card('alignment').querySelector('.ovcs-status--ok')).not.toBeNull()
  })

  it('shows an alignment not yet measured as a dash', () => {
    show({ ...snapshot, alignment: null })

    expect(card('alignment').textContent).toContain('–')
  })

  it("compares the cameras' sharpness, right to left", () => {
    show(snapshot)

    expect(card('sharpness').textContent).toContain('0.70')
    expect(card('sharpness').textContent).toContain('left 0.0312 · right 0.0218')
    expect(card('sharpness').querySelector('.ovcs-status--error')).not.toBeNull()
  })

  it('shows matching sharpness as healthy', () => {
    show({ ...snapshot, sharpness: { left: 0.03, right: 0.028 } })

    expect(card('sharpness').querySelector('.ovcs-status--ok')).not.toBeNull()
  })

  it('shows an unknown CPU usage as a dash', () => {
    show({ ...snapshot, cpu_percent: null })

    expect(card('cpu').textContent).toContain('–')
  })

  it('waits for the first status', () => {
    show(null)

    expect(screen.getByText(/Waiting/)).toBeTruthy()
  })
})
