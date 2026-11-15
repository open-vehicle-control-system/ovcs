import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { exporterStatus, stereoStreams, useExporters } from '../exporters.js'
import * as unit from '../../services/unit.js'

vi.mock('../../services/unit.js')

const initial = useExporters.getState()
const ros2 = { id: 'ros2_zenoh', name: 'ROS 2 · Zenoh', module: 'VisionCore.Ros2.ZenohExporter', status: { level: 'ok', detail: 'Connected' }, outputs: [] }

describe('exporters store', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.mocked(unit.fetchExporters).mockReset()
    useExporters.setState(initial)
  })

  afterEach(() => {
    vi.clearAllTimers()
    vi.useRealTimers()
  })

  it("loads the unit's exporters", async () => {
    vi.mocked(unit.fetchExporters).mockResolvedValue([ros2])

    await useExporters.getState().load()

    expect(useExporters.getState().exporters).toEqual([ros2])
  })

  it('keeps the exporters it has when a load fails', async () => {
    useExporters.setState({ exporters: [ros2] })
    vi.mocked(unit.fetchExporters).mockRejectedValue(new Error('Cannot reach the vision unit'))

    await useExporters.getState().load()

    expect(useExporters.getState().exporters).toEqual([ros2])
  })

  it('tries a failed load again, later each time, until one succeeds', async () => {
    const unreachable = new Error('Cannot reach the vision unit')
    vi.mocked(unit.fetchExporters)
      .mockRejectedValueOnce(unreachable)
      .mockRejectedValueOnce(unreachable)
      .mockResolvedValue([ros2])

    await useExporters.getState().load()
    expect(unit.fetchExporters).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(1000)
    expect(unit.fetchExporters).toHaveBeenCalledTimes(2)

    await vi.advanceTimersByTimeAsync(1999)
    expect(unit.fetchExporters).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(unit.fetchExporters).toHaveBeenCalledTimes(3)
    expect(useExporters.getState().exporters).toEqual([ros2])

    await vi.advanceTimersByTimeAsync(60000)
    expect(unit.fetchExporters).toHaveBeenCalledTimes(3)
  })

  it('keeps the answer of the last load started when an earlier one answers after it', async () => {
    const answers = []
    vi.mocked(unit.fetchExporters).mockImplementation(() => new Promise((resolve) => answers.push(resolve)))

    const earlier = useExporters.getState().load()
    const later = useExporters.getState().load()
    answers[1]([ros2])
    await later
    answers[0]([])
    await earlier

    expect(useExporters.getState().exporters).toEqual([ros2])
  })

  it("takes an exporter's status from the unit status alone: none until it reports one", () => {
    const listed = { id: 'ros2_zenoh', name: 'ROS 2 · Zenoh', status: { level: 'off', detail: 'Listed' } }
    const live = { level: 'ok', detail: 'Connected' }

    expect(exporterStatus(listed, null)).toBeNull()
    expect(exporterStatus(listed, { exporters: [] })).toBeNull()
    expect(exporterStatus(listed, { exporters: [{ id: 'ros2_zenoh', status: live }] })).toEqual(live)
  })
})

describe('stereoStreams', () => {
  it("names the stereo unit's preview streams by the sources the API lists for its frames and its pairs", () => {
    const outputs = [
      { name: 'stereo_frame:left', maxHz: 10, source: 'front/left' },
      { name: 'stereo_frame:right', maxHz: 10, source: 'front/right' },
      { name: 'stereo_pair', maxHz: 10, source: 'front/depth' },
      { name: 'camera_frame:left', maxHz: 10, source: 'left' }
    ]

    expect(stereoStreams(outputs)).toEqual({ left: 'front/left', right: 'front/right', depth: 'front/depth' })
  })

  it('has none before the API lists them, or on a unit without a stereo unit', () => {
    expect(stereoStreams([])).toEqual({ left: null, right: null, depth: null })
  })
})
