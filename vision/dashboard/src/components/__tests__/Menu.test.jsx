import { describe, it, expect, vi, beforeEach } from 'vitest'
import { Profiler } from 'react'
import { render, screen, within, fireEvent, act } from '@testing-library/react'
import Menu from '../Menu.jsx'
import { useParameters } from '../../stores/parameters.js'
import { useNavigation } from '../../stores/navigation.js'
import { useExporters } from '../../stores/exporters.js'
import { useStatus } from '../../stores/status.js'
import { useCalibration } from '../../stores/calibration.js'

vi.mock('../../services/parameters.js')

const group = (id, name, position, pipeline, role = 'step') => ({
  id, name, summary: '', pipeline, role, position, status: null, parameterIds: []
})

const exporter = (id, name) => ({ id, name, module: name, outputs: [] })
const reported = (id, name, level, detail) => ({ id, name, status: { level, detail } })

describe('Menu', () => {
  beforeEach(() => {
    useParameters.setState({
      groups: [
        group('detection.input', 'Input', 101, 'detection'),
        group('stereo.cameras', 'Cameras', 0, 'stereo', 'source'),
        group('stereo.match', 'Match', 2, 'stereo')
      ],
      parameters: {},
      selectedGroupId: null
    })
    useNavigation.setState({ page: 'overview', exporterId: null, calibrationId: null })
    useCalibration.setState({ targets: [], calibrations: {} })
    useExporters.setState({
      exporters: [exporter('ros2_zenoh', 'ROS 2 · Zenoh'), exporter('api', 'API')]
    })
    useStatus.setState({ snapshot: null })
  })

  it("lists the unit's pages in Main, each pipeline's steps in Pipelines and the unit's exporters last", () => {
    render(<Menu />)

    const main = screen.getByRole('region', { name: 'Main' })
    expect(within(main).getAllByRole('button').map((button) => button.textContent)).toEqual(['Overview'])

    const pipelines = screen.getByRole('region', { name: 'Pipelines' })
    expect(within(within(pipelines).getByRole('list', { name: 'Stereo' })).getByRole('button', { name: /^Match/ })).toBeTruthy()
    expect(within(within(pipelines).getByRole('list', { name: 'Detection' })).getByRole('button', { name: /^Input/ })).toBeTruthy()

    const exporters = screen.getByRole('region', { name: 'Exporters' })
    expect(within(exporters).getAllByRole('button').map((button) => button.textContent)).toEqual(['ROS 2 · Zenoh', 'API'])

    const sections = screen.getAllByRole('region').map((region) => region.getAttribute('aria-labelledby'))
    expect(sections.map((id) => document.getElementById(id).textContent)).toEqual(['Main', 'Cameras', 'Pipelines', 'Exporters'])
  })

  describe('Cameras', () => {
    const OVCS1_TARGETS = [
      { id: 'stereo', kind: 'stereo' },
      { id: 'center', kind: 'camera' },
      { id: 'center-pose', kind: 'pose' }
    ]

    const withCenterCamera = () =>
      useParameters.setState((state) => ({
        groups: [...state.groups, group('center.camera', 'Camera', 50, 'center', 'source'), group('objects.input', 'Input', 101, 'objects')]
      }))

    const cameras = () => screen.getByRole('region', { name: 'Cameras' })
    const entries = (list) => within(list).getAllByRole('button').map((button) => button.textContent)
    const camera = (name) => within(cameras()).getByRole('list', { name })
    const entry = (cameraName, name) => within(camera(cameraName)).getByRole('button', { name })

    it('lists the stereo pair, then each camera of its own, each with its settings, calibration and position', () => {
      withCenterCamera()
      useCalibration.setState({ targets: OVCS1_TARGETS })
      render(<Menu />)

      const top = within(cameras()).getByRole('list', { name: 'Cameras' })
      expect([...top.children].map((item) => item.firstElementChild.firstElementChild.textContent)).toEqual([
        'Stereo cameras',
        'Center camera'
      ])
      expect(entries(camera('Stereo cameras'))).toEqual(['Settings', 'Calibration'])
      expect(entries(camera('Center camera'))).toEqual(['Settings', 'Calibration', 'Position'])
    })

    it('says what each calibration covers, without showing it', () => {
      withCenterCamera()
      useCalibration.setState({ targets: OVCS1_TARGETS })
      render(<Menu />)

      expect(entry('Stereo cameras', 'Calibration').getAttribute('title')).toBe('Both lenses and their position to each other')
      expect(entry('Center camera', 'Calibration').getAttribute('title')).toBe('Its lens')
      expect(entry('Center camera', 'Position').getAttribute('title')).toBe('Relative to the stereo pair')
    })

    it('lists no Position under a camera whose position the unit cannot measure', () => {
      withCenterCamera()
      useCalibration.setState({ targets: OVCS1_TARGETS.filter((target) => target.kind !== 'pose') })
      render(<Menu />)

      expect(entries(camera('Center camera'))).toEqual(['Settings', 'Calibration'])
    })

    it('lists the stereo pair alone on a unit without a camera of its own', () => {
      useCalibration.setState({ targets: [{ id: 'stereo', kind: 'stereo' }] })
      render(<Menu />)

      expect(within(cameras()).getAllByRole('list').map((list) => list.getAttribute('aria-label'))).toEqual(['Cameras', 'Stereo cameras'])
      expect(entries(camera('Stereo cameras'))).toEqual(['Settings', 'Calibration'])
    })

    it('has no Cameras section on a unit without a camera', () => {
      useParameters.setState({ groups: [group('detection.input', 'Input', 101, 'detection')] })
      render(<Menu />)

      expect(screen.queryByRole('region', { name: 'Cameras' })).toBeNull()
    })

    it("opens a camera's settings as a step's, and its calibration and position by their ids", () => {
      withCenterCamera()
      useCalibration.setState({ targets: OVCS1_TARGETS })
      render(<Menu />)

      fireEvent.click(entry('Stereo cameras', 'Settings'))
      expect(useNavigation.getState().page).toBe('pipeline')
      expect(useParameters.getState().selectedGroupId).toBe('stereo.cameras')
      expect(entry('Stereo cameras', 'Settings').getAttribute('aria-current')).toBe('true')

      fireEvent.click(entry('Center camera', 'Settings'))
      expect(useParameters.getState().selectedGroupId).toBe('center.camera')

      fireEvent.click(entry('Stereo cameras', 'Calibration'))
      expect(useNavigation.getState()).toMatchObject({ page: 'calibration', calibrationId: 'stereo' })
      expect(entry('Stereo cameras', 'Calibration').getAttribute('aria-current')).toBe('page')
      expect(entry('Center camera', 'Settings').getAttribute('aria-current')).toBeNull()

      fireEvent.click(entry('Center camera', 'Calibration'))
      expect(useNavigation.getState()).toMatchObject({ page: 'calibration', calibrationId: 'center' })

      fireEvent.click(entry('Center camera', 'Position'))
      expect(useNavigation.getState()).toMatchObject({ page: 'calibration', calibrationId: 'center-pose' })
      expect(entry('Center camera', 'Position').getAttribute('aria-current')).toBe('page')
      expect(entry('Center camera', 'Calibration').getAttribute('aria-current')).toBeNull()
      expect(within(cameras()).getAllByRole('button').filter((button) => button.hasAttribute('aria-current'))).toHaveLength(1)
    })

    it('opens its settings from a camera, or its first entry without settings, and is never itself the current page', () => {
      withCenterCamera()
      useCalibration.setState({ targets: [...OVCS1_TARGETS, { id: 'rear', kind: 'camera' }] })
      render(<Menu />)

      const heading = within(cameras()).getByRole('button', { name: 'Center camera' })
      fireEvent.click(heading)
      expect(useNavigation.getState().page).toBe('pipeline')
      expect(useParameters.getState().selectedGroupId).toBe('center.camera')
      expect(heading.getAttribute('aria-current')).toBeNull()

      fireEvent.click(within(cameras()).getByRole('button', { name: 'Rear camera' }))
      expect(useNavigation.getState()).toMatchObject({ page: 'calibration', calibrationId: 'rear' })
    })

    it("shows each camera's state as a dot and its rate at its row's end, and says both", () => {
      withCenterCamera()
      useCalibration.setState({ targets: OVCS1_TARGETS })
      useStatus.setState({
        snapshot: {
          cameras: {
            left: { present: true, fps: 30, issues: [] },
            right: { present: true, fps: 29.96, issues: ['focus_mismatch'] },
            center: { present: true, fps: 0 }
          }
        }
      })
      render(<Menu />)

      const stereo = within(cameras()).getByRole('button', { name: 'Stereo cameras, warning: Softer than the other camera: refocus it, 30 fps' })
      expect(stereo.querySelector('[data-fps]').textContent).toBe('30 fps')
      expect(stereo.querySelector('[data-fps]').className).toContain('text-ovcs-muted')
      expect(stereo.querySelector('.ovcs-status--warn')).not.toBeNull()
      expect(stereo.getAttribute('title')).toBe('Softer than the other camera: refocus it')

      const center = within(cameras()).getByRole('button', { name: 'Center camera, error: no frames, 0 fps' })
      expect(center.querySelector('.ovcs-status--error')).not.toBeNull()
    })

    it('shows neither dot nor rate before the unit reports', () => {
      useCalibration.setState({ targets: OVCS1_TARGETS })
      render(<Menu />)

      const stereo = within(cameras()).getByRole('button', { name: 'Stereo cameras' })
      expect(stereo.querySelector('.ovcs-status, [data-fps]')).toBeNull()
    })

    it("marks a camera's settings with their unsaved count, their warning and the cameras' latency", () => {
      useParameters.setState({
        groups: [
          {
            ...group('stereo.cameras', 'Cameras', 0, 'stereo', 'source'),
            status: { level: 'warning', detail: 'exposure capped' },
            parameterIds: ['a', 'b']
          },
          group('stereo.match', 'Match', 2, 'stereo')
        ],
        parameters: { a: { id: 'a', name: 'a', state: 'unsaved' }, b: { id: 'b', name: 'b', state: 'unsaved' } }
      })
      useStatus.setState({ snapshot: { latencies: { stereo: { cameras: 4.21, pairing: null } } } })
      render(<Menu />)

      const settings = entry('Stereo cameras', /^Settings/)
      expect(settings.querySelector('[translate="no"]').textContent).toBe('Settings')
      expect(settings.textContent).toContain('2')
      expect(settings.querySelector('[data-latency]').textContent).toBe('4.2 ms')
      expect(settings.className).toContain('border-ovcs-error')
      expect(settings.getAttribute('aria-label')).toBe('Settings, capture to unit 4.2 ms, not in the total, 2 unsaved, warning: exposure capped')
    })

    it("says at its row's end that a camera's position is not measured, once the unit has pushed it", () => {
      withCenterCamera()
      useCalibration.setState({ targets: OVCS1_TARGETS, calibrations: {} })
      const { unmount } = render(<Menu />)
      expect(entry('Center camera', 'Position').textContent).toBe('Position')
      unmount()

      useCalibration.setState({ calibrations: { 'center-pose': { id: 'center-pose', kind: 'pose', source: 'none' } } })
      render(<Menu />)
      const position = entry('Center camera', 'Position, not measured')
      expect(position.querySelector('[data-state]').textContent).toBe('not measured')
      expect(position.querySelector('[data-state]').className).toContain('text-ovcs-muted')
      act(() => useCalibration.setState({ calibrations: { 'center-pose': { id: 'center-pose', kind: 'pose', source: 'stored' } } }))
      expect(entry('Center camera', 'Position').querySelector('[data-state]')).toBeNull()
    })

    it("does not render again when the status changes none of the cameras' states or rates", () => {
      useCalibration.setState({ targets: OVCS1_TARGETS })
      const reported = (exposureTimeUs) => ({
        snapshot: {
          cameras: {
            left: { present: true, fps: 30, issues: [], exposureTimeUs },
            right: { present: true, fps: 30, issues: [], exposureTimeUs },
            center: { present: true, fps: 30, exposureTimeUs }
          }
        }
      })
      useStatus.setState(reported(1000))
      const commits = vi.fn()
      render(
        <Profiler id="menu" onRender={commits}>
          <Menu />
        </Profiler>
      )
      commits.mockClear()

      act(() => useStatus.setState(reported(2000)))
      expect(commits).not.toHaveBeenCalled()
    })
  })

  it('marks each exporter with the status the unit status reports for it, and opens its page', () => {
    useExporters.setState({ exporters: [exporter('ros2_zenoh', 'ROS 2 · Zenoh'), exporter('recorder', 'Recorder'), exporter('api', 'API')] })
    useStatus.setState({
      snapshot: { exporters: [reported('ros2_zenoh', 'ROS 2 · Zenoh', 'ok', 'Connected'), reported('recorder', 'Recorder', 'off', 'Not running')] }
    })
    render(<Menu />)

    const exporters = screen.getByRole('region', { name: 'Exporters' })
    const ros2 = within(exporters).getByRole('button', { name: 'ROS 2 · Zenoh, ok: Connected' })
    expect(ros2.querySelector('.ovcs-status')).toBeNull()
    const recorder = within(exporters).getByRole('button', { name: 'Recorder, off: Not running' })
    expect(recorder.querySelector('.ovcs-status')).not.toBeNull()
    expect(recorder.className).toContain('border-dashed')

    fireEvent.click(recorder)
    expect(useNavigation.getState()).toMatchObject({ page: 'exporter', exporterId: 'recorder' })
    expect(recorder.getAttribute('aria-current')).toBe('page')
  })

  it('marks an exporter whose status is a warning in red', () => {
    useStatus.setState({ snapshot: { exporters: [reported('ros2_zenoh', 'ROS 2 · Zenoh', 'warning', 'Disconnected')] } })
    render(<Menu />)

    const ros2 = within(screen.getByRole('region', { name: 'Exporters' })).getByRole('button', { name: 'ROS 2 · Zenoh, warning: Disconnected' })
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
