import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, fireEvent, render, screen, within } from '@testing-library/react'
import ExporterPage from '../ExporterPage.jsx'
import { useExporters } from '../../stores/exporters.js'
import { useStatus } from '../../stores/status.js'

vi.mock('../../services/parameters.js')
const { runExporterAction } = vi.hoisted(() => ({ runExporterAction: vi.fn() }))
vi.mock('../../services/unit.js', () => ({ fetchRos2Node: () => new Promise(() => {}), runExporterAction }))

const recorder = {
  id: 'recorder',
  name: 'Recorder',
  module: 'MyCar.Recorder',
  status: { level: 'warning', detail: 'Disk full' },
  outputs: [
    { name: 'stereo_pair', maxHz: 2 },
    { name: 'camera_frame:left', maxHz: null },
    { name: 'detections', maxHz: null },
    { name: 'detections:road_signs', maxHz: 5 },
    { name: 'camera_frame:center', maxHz: 5 },
    { name: 'camera_frame:center:inference', maxHz: null },
    { name: 'segmentation:scene', maxHz: 5 }
  ]
}

const debug = {
  id: 'debug',
  name: 'Debug',
  module: 'VisionCore.Debug.Exporter',
  status: { level: 'ok', detail: 'Ready' },
  outputs: [],
  actions: [
    { name: 'export', label: 'Export', description: 'Records a burst and answers it as a zip.' },
    { name: 'clear', label: 'Clear', description: 'Forgets the last recording.' }
  ]
}

describe('ExporterPage', () => {
  beforeEach(() => {
    useExporters.setState({ exporters: [recorder, debug] })
    useStatus.setState({ snapshot: null })
    runExporterAction.mockReset()
  })

  it('shows an exporter without a page of its own: its status, module and the outputs it reads', () => {
    useStatus.setState({ snapshot: { exporters: [{ id: 'recorder', name: 'Recorder', status: { level: 'warning', detail: 'Disk full' } }] } })
    render(<ExporterPage id="recorder" />)

    expect(screen.getByRole('heading', { name: 'Recorder' })).toBeTruthy()
    expect(screen.getByText('Disk full').closest('.ovcs-status--error')).not.toBeNull()
    expect(screen.getByText('MyCar.Recorder')).toBeTruthy()

    const rows = within(screen.getByRole('table')).getAllByRole('row').slice(1)
    expect(rows.map((row) => row.textContent)).toEqual([
      'Stereo pairsat most 2 Hz',
      'Left camera framesthe newest, unbounded',
      'Detectionsthe newest, unbounded',
      'Detections: road_signsat most 5 Hz',
      'Camera frames: centerat most 5 Hz',
      'Camera frames: center, inferencethe newest, unbounded',
      'Segmentation: sceneat most 5 Hz'
    ])
  })

  it('shows the live status of the unit status first', () => {
    useStatus.setState({ snapshot: { exporters: [{ id: 'recorder', name: 'Recorder', status: { level: 'ok', detail: 'Recording' } }] } })
    render(<ExporterPage id="recorder" />)

    expect(screen.getByText('Recording').closest('.ovcs-status--ok')).not.toBeNull()
  })

  it('opens the pages of the ROS 2 · Zenoh exporter and the API', () => {
    render(<ExporterPage id="ros2_zenoh" />)
    expect(screen.getByRole('heading', { name: 'ROS 2 · Zenoh' })).toBeTruthy()

    render(<ExporterPage id="api" />)
    expect(screen.getByRole('heading', { name: 'API' })).toBeTruthy()
  })

  it('waits for an exporter the unit has not listed yet', () => {
    render(<ExporterPage id="mqtt" />)

    expect(screen.getByText(/has not listed an exporter mqtt/)).toBeTruthy()
  })

  it('shows a button per action of an exporter without a page of its own', () => {
    render(<ExporterPage id="debug" />)

    const actions = screen.getAllByRole('button')
    expect(actions.map((button) => button.textContent)).toEqual(['Export', 'Clear'])
    expect(screen.getByRole('button', { name: 'Export' }).getAttribute('aria-describedby')).toBe(
      screen.getByText('Records a burst and answers it as a zip.').id
    )
    expect(screen.getByText('Forgets the last recording.')).toBeTruthy()
  })

  it('shows no button for an exporter without actions', () => {
    render(<ExporterPage id="recorder" />)

    expect(screen.queryByRole('button')).toBeNull()
  })

  describe('running an action', () => {
    let click
    let created

    beforeEach(() => {
      created = []
      URL.createObjectURL = vi.fn(() => {
        created.push(`blob:${created.length}`)
        return created.at(-1)
      })
      URL.revokeObjectURL = vi.fn()
      click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    })

    afterEach(() => {
      vi.useRealTimers()
      click.mockRestore()
      delete URL.createObjectURL
      delete URL.revokeObjectURL
    })

    it('runs the action, shows it running, then downloads the file', async () => {
      vi.useFakeTimers()
      let finish
      runExporterAction.mockReturnValue(new Promise((resolve) => (finish = resolve)))
      render(<ExporterPage id="debug" />)

      fireEvent.click(screen.getByRole('button', { name: 'Export' }))

      expect(runExporterAction).toHaveBeenCalledWith('debug', 'export')
      const running = screen.getByRole('button', { name: 'Running…' })
      expect(running.disabled).toBe(true)
      expect(screen.getByRole('button', { name: 'Clear' }).disabled).toBe(true)

      const blob = new Blob(['zip'])
      await act(async () => finish({ kind: 'file', blob, filename: 'vision-export.zip' }))

      expect(URL.createObjectURL).toHaveBeenCalledWith(blob)
      const link = click.mock.contexts[0]
      expect(link.download).toBe('vision-export.zip')
      expect(link.getAttribute('href')).toBe('blob:0')
      expect(URL.revokeObjectURL).not.toHaveBeenCalled()

      vi.runAllTimers()
      expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:0')
      expect(screen.getByRole('button', { name: 'Export' }).disabled).toBe(false)
      expect(screen.queryByRole('alert')).toBeNull()
    })

    it("shows the error's detail when the action fails", async () => {
      runExporterAction.mockRejectedValue(new Error('exporter debug is busy'))
      render(<ExporterPage id="debug" />)

      await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Export' })))

      expect(screen.getByRole('alert').textContent).toBe('exporter debug is busy')
      expect(click).not.toHaveBeenCalled()
      expect(screen.getByRole('button', { name: 'Export' }).disabled).toBe(false)
    })

    it('shows the result of an action that answers JSON, and drops it and an error on the next run', async () => {
      runExporterAction.mockResolvedValueOnce({ kind: 'json', data: { cleared: 3 } })
      render(<ExporterPage id="debug" />)

      await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Clear' })))
      expect(JSON.parse(screen.getByRole('status').textContent)).toEqual({ cleared: 3 })
      expect(click).not.toHaveBeenCalled()

      runExporterAction.mockRejectedValueOnce(new Error('exporter debug is busy'))
      await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Export' })))
      expect(screen.queryByRole('status')).toBeNull()
      expect(screen.getByRole('alert')).toBeTruthy()

      runExporterAction.mockResolvedValueOnce({ kind: 'json', data: { cleared: 0 } })
      await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Clear' })))
      expect(screen.queryByRole('alert')).toBeNull()
    })
  })
})
