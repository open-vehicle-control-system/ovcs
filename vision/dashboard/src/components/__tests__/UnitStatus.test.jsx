import { describe, it, expect, vi } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import UnitStatus from '../UnitStatus.jsx'
import Previews from '../Previews.jsx'

const socket = { channel: vi.fn(() => ({ on: vi.fn(), join: vi.fn(() => ({ receive() { return this } })), push: vi.fn(() => ({ receive() { return this } })), off: vi.fn(), onError: vi.fn(), leave: vi.fn() })) }

const snapshot = {
  cameras: { left: { present: true, fps: 29.6, exposureTimeUs: 8000, analogueGain: 2.0 }, right: { present: false } },
  sync: { present: true, offsetMedianMs: 0.12, offsetMaxMs: 0.4, pairs: 150 },
  npu: null,
  depthHz: 12.8,
  exporters: [{ id: 'ros2_zenoh', name: 'ROS 2 · Zenoh', status: { level: 'warning', detail: 'Disconnected' } }],
  cpuPercent: 37.25,
  stereoLoadPercent: 81.5,
  alignment: { offsetRows: -1.43, bandOffsetRows: [-1.9, -1.6, -1.2, -1.0] },
  sharpness: { left: 0.0312, right: 0.0218 },
  pair: {
    timing: { level: 'ok', camera: null, issues: [], gauge: 0.12, later: 'right', offsetMs: 0.12, maxOffsetMs: 0.4, pairs: 150 },
    rows: {
      gauge: 2.5,
      level: 'warning',
      camera: 'right',
      issues: ['row_offset', 'large_row_correction'],
      direction: 'higher',
      misalignmentRows: 7.43,
      offsetRows: -1.43,
      correctionRows: -6.0,
      bandOffsetRows: [-1.9, -1.6, -1.2, -1.0],
      bandSpreadRows: 0.9
    },
    focus: {
      gauge: 1.2,
      level: 'warning',
      camera: 'right',
      issues: ['focus_mismatch'],
      softer: 'right',
      differencePercent: 30,
      ratio: 0.7,
      left: 0.0312,
      right: 0.0218
    }
  }
}

describe('UnitStatus and the pair status', () => {
  const card = (id) => document.querySelector(`[data-card="${id}"]`)
  const show = (status) =>
    render(
      <>
        <ul>
          <UnitStatus status={status} />
        </ul>
        <Previews status={status} socket={socket} />
      </>
    )

  it('shows no NPU as none in grey: a unit without an accelerator is not failing', () => {
    show(snapshot)
    expect(card('npu').textContent).toContain('NPU')
    expect(card('npu').textContent).toContain('none')
    expect(card('npu').querySelector('.ovcs-status--error')).toBeNull()
    expect(card('npu').querySelector('.ovcs-status--ok')).toBeNull()
  })

  it('shows a running NPU by its kind', () => {
    show({ ...snapshot, npu: { kind: 'Hailo-8', state: 'running' } })
    expect(card('npu').textContent).toContain('Hailo-8')
    expect(card('npu').querySelector('.ovcs-status--ok')).not.toBeNull()
  })

  it("shows the NPU's load beside its kind", () => {
    show({ ...snapshot, npu: { kind: 'Hexagon', state: 'running', loadPercent: 63.6, pipelines: {} } })
    expect(card('npu').textContent).toContain('Hexagon 64 %')
    expect(card('npu').querySelector('.ovcs-status--ok')).not.toBeNull()
  })

  it('shows the NPU by its kind alone while no load is known', () => {
    show({ ...snapshot, npu: { kind: 'Hexagon', state: 'running', loadPercent: null, pipelines: {} } })
    expect(card('npu').textContent).toContain('Hexagon')
    expect(card('npu').textContent).not.toContain('%')
  })

  it('shows an NPU whose backend is starting as starting in grey: it has not failed', () => {
    show({ ...snapshot, npu: { kind: 'Hexagon', state: 'starting', loadPercent: null, pipelines: {} } })
    expect(card('npu').textContent).toContain('starting')
    expect(card('npu').querySelector('.ovcs-status--error')).toBeNull()
    expect(card('npu').querySelector('.ovcs-status--ok')).toBeNull()
    expect(card('npu').querySelector('[data-warning]')).toBeNull()
    expect(card('npu').textContent).not.toContain('unhealthy')
  })

  it('shows an NPU that failed by its kind, in red', () => {
    show({ ...snapshot, npu: { kind: 'Hexagon', state: 'failed' } })
    expect(card('npu').textContent).toContain('Hexagon')
    expect(card('npu').querySelector('.ovcs-status--error')).not.toBeNull()
  })

  it("shows the ROS 2 exporter's status in the top bar", () => {
    show(snapshot)

    expect(card('ros2').textContent).toContain('ROS 2')
    expect(card('ros2').textContent).toContain('disconnected')
    expect(card('ros2').querySelector('.ovcs-status--error')).not.toBeNull()
  })

  it('shows a connected ROS 2 exporter as healthy, and none without a ROS 2 exporter', () => {
    show({ ...snapshot, exporters: [{ id: 'ros2_zenoh', name: 'ROS 2 · Zenoh', status: { level: 'ok', detail: 'Connected' } }] })
    expect(card('ros2').querySelector('.ovcs-status--ok')).not.toBeNull()
    cleanup()

    show({ ...snapshot, exporters: [{ id: 'recorder', name: 'Recorder', status: { level: 'ok', detail: 'Recording' } }] })
    expect(card('ros2')).toBeNull()
  })

  it('leaves the CPU usage to the top bar, and shows the stereo stages\' busy time as the stereo load, explained by its hint', () => {
    show(snapshot)

    expect(card('cpu')).toBeNull()
    expect(card('segment').textContent).toContain('Stereo load')
    expect(card('segment').textContent).not.toContain('GPU')
    expect(card('segment').textContent).toContain('82 %')
    expect(card('segment').querySelector('button').getAttribute('aria-label')).toBe('About Stereo load')
  })

  it('warns of the stereo load from 97 %, where a pair takes nearly a frame', () => {
    show({ ...snapshot, stereoLoadPercent: 96.9 })
    expect(card('segment').querySelector('[data-warning]')).toBeNull()
    cleanup()

    show({ ...snapshot, stereoLoadPercent: 97 })
    expect(card('segment').querySelector('[data-warning]')).not.toBeNull()
  })

  it("shows each check's value and short detail, its figures and issues on hover", () => {
    show(snapshot)

    expect(card('rows').textContent).toContain('Rows')
    expect(card('rows').textContent).toContain('7.4 rows')
    expect(card('rows').querySelector('.ovcs-status--error')).not.toBeNull()
    expect(card('rows').querySelector('[data-detail]').textContent).toBe('right higher · corrected -6.0')
    expect(card('rows').title).toBe(
      'left to right -1.9 · -1.6 · -1.2 · -1.0\nRows apart: recalibrate\nRows held by a large correction: recalibrate'
    )
  })

  it("puts each check's cursor where the unit places it, toward the camera it concerns, held at the track's ends", () => {
    show(snapshot)

    const cursor = (id) => card(id).querySelector('[data-cursor]')
    expect(cursor('timing').style.left).toBe('53%')
    expect(cursor('focus').style.left).toBe('80%')
    expect(cursor('rows').style.left).toBe('100%')
    expect(cursor('rows').classList).toContain('bg-ovcs-warn')
    expect(cursor('timing').classList).toContain('bg-ovcs-ok')
  })

  it('shows a check the unit judges ok as healthy', () => {
    show({ ...snapshot, pair: { ...snapshot.pair, rows: { ...snapshot.pair.rows, level: 'ok', camera: null, issues: [] } } })

    expect(card('rows').querySelector('.ovcs-status--ok')).not.toBeNull()
    expect(card('rows').querySelector('[data-cursor]').classList).toContain('bg-ovcs-ok')
  })

  it('shows a check with nothing to judge as a dash, its gauge without a cursor', () => {
    show({ ...snapshot, pair: { ...snapshot.pair, rows: { level: 'off', camera: null, issues: [] } } })

    expect(card('rows').textContent).toContain('–')
    expect(card('rows').querySelector('[data-cursor]')).toBeNull()
  })

  it('shows the focus difference and the softer camera, each sharpness on hover', () => {
    show(snapshot)

    expect(card('focus').textContent).toContain('30 %')
    expect(card('focus').querySelector('[data-detail]').textContent).toBe('right softer')
    expect(card('focus').title).toContain('left 0.0312 · right 0.0218')
    expect(card('focus').querySelector('.ovcs-status--error')).not.toBeNull()
  })

  it('shows the timing offset and the later camera, the pairs on hover', () => {
    show(snapshot)

    expect(card('timing').textContent).toContain('0.12 ms')
    expect(card('timing').querySelector('[data-detail]').textContent).toBe('right later · max 0.40')
    expect(card('timing').title).toBe('over 150 pairs')
  })

  it('marks an unhealthy value beyond its colour: a warning sign, and words for a screen reader', () => {
    show(snapshot)

    for (const id of ['ros2', 'rows', 'focus', 'right']) {
      expect(card(id).querySelector('[data-warning]')).not.toBeNull()
      expect(card(id).textContent).toContain(', unhealthy')
    }
    for (const id of ['npu', 'segment', 'timing', 'left']) {
      expect(card(id).querySelector('[data-warning]')).toBeNull()
      expect(card(id).textContent).not.toContain('unhealthy')
    }
  })

  it('keeps each top bar value as wide as its widest form, warning sign included, so the line does not move', () => {
    show({ ...snapshot, npu: { kind: 'Hexagon', state: 'running', loadPercent: 5, pipelines: {} }, stereoLoadPercent: 98 })

    const widest = (id) => card(id).querySelector('[data-widest]').dataset.widest
    expect(widest('ros2')).toBe('not answering')
    expect(widest('npu')).toBe('Hexagon 100 %')
    expect(widest('segment')).toBe('100 %')
    for (const id of ['ros2', 'npu', 'segment']) expect(card(id).querySelector('[data-warning-slot]')).not.toBeNull()
  })

  it('says an uncalibrated unit is uncalibrated, and nothing about a calibrated one', () => {
    show({ ...snapshot, calibrated: false })
    expect(card('calibration').textContent).toContain('uncalibrated')
    expect(card('calibration').querySelector('.ovcs-status--error')).not.toBeNull()
    cleanup()

    show({ ...snapshot, calibrated: true })
    expect(card('calibration')).toBeNull()
  })
})
