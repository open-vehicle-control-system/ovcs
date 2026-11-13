import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { exporterStatus, useExporters } from '../exporters.js'
import * as unit from '../../services/unit.js'

vi.mock('../../services/unit.js')

const initial = useExporters.getState()
const ros2 = { id: 'ros2', name: 'ROS 2', module: 'VisionCore.Ros2.Exporter', status: { level: 'ok', detail: 'Connected' }, outputs: [] }

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

  it("takes an exporter's status from the unit status alone: none until it reports one", () => {
    const listed = { id: 'ros2', name: 'ROS 2', status: { level: 'off', detail: 'Listed' } }
    const live = { level: 'ok', detail: 'Connected' }

    expect(exporterStatus(listed, null)).toBeNull()
    expect(exporterStatus(listed, { exporters: [] })).toBeNull()
    expect(exporterStatus(listed, { exporters: [{ id: 'ros2', status: live }] })).toEqual(live)
  })
})
