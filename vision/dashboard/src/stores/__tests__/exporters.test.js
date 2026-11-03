import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useExporters } from '../exporters.js'
import * as unit from '../../services/unit.js'

vi.mock('../../services/unit.js')

const ros2 = { id: 'ros2', name: 'ROS 2', module: 'VisionCore.Ros2.Exporter', status: { level: 'ok', detail: 'Connected' }, outputs: [] }

describe('exporters store', () => {
  beforeEach(() => useExporters.setState({ exporters: [] }))

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
})
