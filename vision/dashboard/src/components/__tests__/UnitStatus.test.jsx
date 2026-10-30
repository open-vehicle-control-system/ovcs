import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import StatusCards from '../StatusCards.jsx'

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

describe('StatusCards', () => {
  const card = (id) => document.querySelector(`[data-card="${id}"]`)
  const show = (status) => render(<StatusCards status={status} />)

  it('shows Hailo absent', () => {
    show(snapshot)

    expect(card('hailo').textContent).toContain('absent')
  })

  it('shows each camera, the depth rate and Zenoh', () => {
    show(snapshot)

    expect(card('left').textContent).toContain('29.6')
    expect(card('right').textContent).toContain('absent')
    expect(card('depth').textContent).toContain('12.8')
    expect(card('zenoh').textContent).toContain('disconnected')
  })

  it('shows the CPU usage and the stereo segment time', () => {
    show(snapshot)

    expect(card('cpu').textContent).toContain('37 %')
    expect(card('segment').textContent).toContain('82 %')
  })

  it('shows the row alignment, overall and from left to right', () => {
    show(snapshot)

    expect(card('alignment').textContent).toContain('-1.4 rows')
    expect(card('alignment').textContent).toContain('-1.9 · -1.6 · -1.2 · -1.0')
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
