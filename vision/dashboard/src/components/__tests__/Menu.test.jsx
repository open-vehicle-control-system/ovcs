import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import Menu from '../Menu.jsx'
import { useParameters } from '../../stores/parameters.js'
import { useNavigation } from '../../stores/navigation.js'
import { useExporters } from '../../stores/exporters.js'
import { useStatus } from '../../stores/status.js'

vi.mock('../../services/parameters.js')

const group = (id, name, position, pipeline, role = 'step') => ({
  id, name, summary: '', pipeline, role, position, status: null, parameterIds: []
})

const exporter = (id, name) => ({ id, name, module: name, outputs: [] })
const reported = (id, name, level, detail) => ({ id, name, status: { level, detail } })

describe('Menu', () => {
  beforeEach(() => {
    useParameters.setState({
      groups: [group('detection.input', 'Input', 101, 'detection'), group('cameras', 'Cameras', 0, 'stereo', 'source')],
      parameters: {},
      selectedGroupId: null
    })
    useNavigation.setState({ page: 'overview', exporterId: null })
    useExporters.setState({
      exporters: [exporter('ros2', 'ROS 2'), exporter('api', 'API')]
    })
    useStatus.setState({ snapshot: null })
  })

  it("lists the unit's pages in Main, each pipeline's steps in Pipelines and the unit's exporters last", () => {
    render(<Menu />)

    const main = screen.getByRole('region', { name: 'Main' })
    expect(within(main).getAllByRole('button').map((button) => button.textContent)).toEqual(['Overview', 'Calibration'])

    const pipelines = screen.getByRole('region', { name: 'Pipelines' })
    expect(within(within(pipelines).getByRole('list', { name: 'Stereo' })).getByRole('button', { name: 'Cameras' })).toBeTruthy()
    expect(within(within(pipelines).getByRole('list', { name: 'Detection' })).getByRole('button', { name: /^Input/ })).toBeTruthy()

    const exporters = screen.getByRole('region', { name: 'Exporters' })
    expect(within(exporters).getAllByRole('button').map((button) => button.textContent)).toEqual(['ROS 2', 'API'])
  })

  it('marks each exporter with the status the unit status reports for it, and opens its page', () => {
    useExporters.setState({ exporters: [exporter('ros2', 'ROS 2'), exporter('recorder', 'Recorder'), exporter('api', 'API')] })
    useStatus.setState({
      snapshot: { exporters: [reported('ros2', 'ROS 2', 'ok', 'Connected'), reported('recorder', 'Recorder', 'off', 'Not running')] }
    })
    render(<Menu />)

    const exporters = screen.getByRole('region', { name: 'Exporters' })
    const ros2 = within(exporters).getByRole('button', { name: 'ROS 2, ok: Connected' })
    expect(ros2.querySelector('.ovcs-status')).toBeNull()
    const recorder = within(exporters).getByRole('button', { name: 'Recorder, off: Not running' })
    expect(recorder.querySelector('.ovcs-status')).not.toBeNull()
    expect(recorder.className).toContain('border-dashed')

    fireEvent.click(recorder)
    expect(useNavigation.getState()).toMatchObject({ page: 'exporter', exporterId: 'recorder' })
    expect(recorder.getAttribute('aria-current')).toBe('page')
  })

  it('marks an exporter whose status is a warning in red', () => {
    useStatus.setState({ snapshot: { exporters: [reported('ros2', 'ROS 2', 'warning', 'Disconnected')] } })
    render(<Menu />)

    const ros2 = within(screen.getByRole('region', { name: 'Exporters' })).getByRole('button', { name: 'ROS 2, warning: Disconnected' })
    expect(ros2.querySelector('.ovcs-status--error')).not.toBeNull()
  })

  it('shows the detection pipeline greyed, with nothing to select, on a unit without a detector', () => {
    useParameters.setState({ groups: [group('cameras', 'Cameras', 0, 'stereo', 'source')] })
    render(<Menu />)

    const pipelines = screen.getByRole('region', { name: 'Pipelines' })
    expect(within(pipelines).getByText('No detector on this unit')).toBeTruthy()
    expect(within(pipelines).queryByRole('button', { name: /Detection/ })).toBeNull()
  })

  it('lists a named pipeline without the greyed detection line', () => {
    useParameters.setState({
      groups: [group('cameras', 'Cameras', 0, 'stereo', 'source'), group('road_signs.input', 'Input', 101, 'road_signs')]
    })
    render(<Menu />)

    const pipelines = screen.getByRole('region', { name: 'Pipelines' })
    expect(within(pipelines).getByRole('list', { name: 'Road signs' })).toBeTruthy()
    expect(within(pipelines).queryByText('No detector on this unit')).toBeNull()
  })
})
