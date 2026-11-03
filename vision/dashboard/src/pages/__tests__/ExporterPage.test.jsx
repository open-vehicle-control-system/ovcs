import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import ExporterPage from '../ExporterPage.jsx'
import { useExporters } from '../../stores/exporters.js'
import { useStatus } from '../../stores/status.js'

vi.mock('../../services/parameters.js')
vi.mock('../../services/unit.js', () => ({ fetchRos2Node: () => new Promise(() => {}) }))

const recorder = {
  id: 'recorder',
  name: 'Recorder',
  module: 'MyCar.Recorder',
  status: { level: 'warning', detail: 'Disk full' },
  outputs: [
    { name: 'stereo_pair', maxHz: 2 },
    { name: 'camera_frame:left', maxHz: null },
    { name: 'detections', maxHz: null }
  ]
}

describe('ExporterPage', () => {
  beforeEach(() => {
    useExporters.setState({ exporters: [recorder] })
    useStatus.setState({ snapshot: null })
  })

  it('shows an exporter without a page of its own: its status, module and the outputs it reads', () => {
    render(<ExporterPage id="recorder" />)

    expect(screen.getByRole('heading', { name: 'Recorder' })).toBeTruthy()
    expect(screen.getByText('Disk full').closest('.ovcs-status--error')).not.toBeNull()
    expect(screen.getByText('MyCar.Recorder')).toBeTruthy()

    const rows = within(screen.getByRole('table')).getAllByRole('row').slice(1)
    expect(rows.map((row) => row.textContent)).toEqual([
      'Stereo pairsat most 2 Hz',
      'Left camera framesthe newest, unbounded',
      'Detectionsthe newest, unbounded'
    ])
  })

  it('shows the live status of the unit status first', () => {
    useStatus.setState({ snapshot: { exporters: [{ id: 'recorder', name: 'Recorder', status: { level: 'ok', detail: 'Recording' } }] } })
    render(<ExporterPage id="recorder" />)

    expect(screen.getByText('Recording').closest('.ovcs-status--ok')).not.toBeNull()
  })

  it('opens the pages of the ROS 2 exporter and the API', () => {
    render(<ExporterPage id="ros2" />)
    expect(screen.getByRole('heading', { name: 'ROS 2' })).toBeTruthy()

    render(<ExporterPage id="api" />)
    expect(screen.getByRole('heading', { name: 'API' })).toBeTruthy()
  })

  it('waits for an exporter the unit has not listed yet', () => {
    render(<ExporterPage id="mqtt" />)

    expect(screen.getByText(/has not listed an exporter mqtt/)).toBeTruthy()
  })
})
