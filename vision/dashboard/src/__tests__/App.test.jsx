import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act, fireEvent, within } from '@testing-library/react'
import App from '../App.jsx'
import { useParameters } from '../stores/parameters.js'
import { calibrationFromUrl, exporterFromUrl, pageFromUrl, useNavigation } from '../stores/navigation.js'
import { useExporters } from '../stores/exporters.js'
import { useCalibration } from '../stores/calibration.js'
import * as service from '../services/parameters.js'
import { dashboardSocket } from '../services/socket.js'
import { useStatus } from '../stores/status.js'

vi.mock('../services/parameters.js')
vi.mock('../services/socket.js', () => ({
  dashboardSocket: {
    isConnected: vi.fn(() => true),
    onOpen: () => 'open',
    onClose: () => 'close',
    onError: () => 'error',
    off: () => {},
    channel: vi.fn(() => ({ on: () => {}, join: () => ({ receive() { return this } }), off: () => {}, onError: () => {}, leave: vi.fn(), push: () => ({ receive() { return this } }) }))
  }
}))

const group = (id, name, position, { pipeline = 'stereo', role = 'step' } = {}) => ({
  id, name, summary: '', pipeline, role, position, status: null, parameterIds: []
})

const groups = [
  group('detection.input', 'Input', 101, { pipeline: 'detection' }),
  group('stereo.match', 'Match', 2),
  group('cameras', 'Cameras', 1, { role: 'source' })
]

const exporters = [
  { id: 'ros2', name: 'ROS 2', module: 'VisionCore.Ros2.Exporter', status: { level: 'ok', detail: 'Connected' }, outputs: [] },
  {
    id: 'recorder',
    name: 'Recorder',
    module: 'MyCar.Recorder',
    status: { level: 'ok', detail: 'Recording' },
    outputs: [{ name: 'stereo_pair', maxHz: 2 }]
  },
  { id: 'api', name: 'API', module: 'VisionApiWeb.Endpoint', status: { level: 'ok', detail: 'Answering' }, outputs: [] }
]

const initial = useParameters.getState()

describe('App', () => {
  let actions
  beforeEach(() => {
    actions = { startPolling: vi.fn(), stopPolling: vi.fn() }
    dashboardSocket.channel.mockClear()
    dashboardSocket.isConnected.mockReturnValue(true)
    useParameters.setState({ ...initial, ...actions, groups: [], parameters: {}, unsaved: 0, selectedGroupId: null })
    useExporters.setState({ exporters })
    useStatus.setState({ snapshot: null, joins: 0 })
    useCalibration.setState({ targets: [], session: null, calibrations: {}, saved: {}, selected: null })
    visit('/')
  })

  // Opens the dashboard at `path`, as a reload would.
  const visit = (path) => {
    window.history.replaceState(null, '', path)
    useNavigation.setState({ page: pageFromUrl(), exporterId: exporterFromUrl(), calibrationId: calibrationFromUrl() })
  }

  it('polls the parameters while mounted', () => {
    const { unmount } = render(<App />)
    expect(actions.startPolling).toHaveBeenCalledTimes(1)
    expect(actions.stopPolling).not.toHaveBeenCalled()

    unmount()
    expect(actions.stopPolling).toHaveBeenCalledTimes(1)
  })

  it('offers the dark mode switch in the top bar', () => {
    render(<App />)

    expect(within(screen.getByRole('banner')).getByRole('switch', { name: 'Dark mode' })).toBeTruthy()
  })

  it('selects the box named in the URL once the groups are loaded', () => {
    visit('/?box=stereo.match')
    render(<App />)
    expect(useParameters.getState().selectedGroupId).toBeNull()

    act(() => useParameters.setState({ groups }))
    expect(useParameters.getState().selectedGroupId).toBe('stereo.match')
    expect(screen.getByRole('heading', { name: 'Match' })).toBeTruthy()
  })

  it("selects the first pipeline's first box when the URL names an unknown one", () => {
    visit('/?box=gone')
    useParameters.setState({ groups })
    render(<App />)
    expect(useParameters.getState().selectedGroupId).toBe('cameras')
    expect(window.location.search).toBe('?box=cameras')
  })

  it('keeps the selected box in the URL', () => {
    visit('/?box=cameras')
    useParameters.setState({ groups })
    render(<App />)

    act(() => useParameters.getState().select('stereo.match'))
    expect(window.location.search).toBe('?box=stereo.match')
  })

  it('shows the save bar with the unsaved count', () => {
    visit('/?box=cameras')
    useParameters.setState({ groups, unsaved: 2 })
    render(<App />)
    expect(screen.getByRole('button', { name: 'Save 2 changes' })).toBeTruthy()
  })

  it('shows a failed save in the top bar, dismissable, and keeps the count', async () => {
    vi.mocked(service.saveParameters).mockRejectedValue(new Error('Saved values unavailable'))
    vi.mocked(service.fetchGroups).mockResolvedValue({ groups, parameters: {}, unsaved: 2 })
    visit('/?box=cameras')
    useParameters.setState({ groups, unsaved: 2 })
    render(<App />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Save 2 changes' })))

    const alert = screen.getByRole('alert')
    expect(alert.textContent).toContain('Saved values unavailable')
    expect(alert.closest('header')).not.toBeNull()
    expect(screen.getByRole('button', { name: 'Save 2 changes' })).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Dismiss error' }))
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('shows a failed load in the top bar until a load succeeds, with nothing to dismiss', () => {
    useParameters.setState({ groups, error: 'Cannot reach the vision unit', errorSource: 'load' })
    render(<App />)

    const alert = screen.getByRole('alert')
    expect(alert.closest('header')).not.toBeNull()
    expect(alert.textContent).toContain('Cannot reach the vision unit')
    expect(screen.queryByRole('button', { name: 'Dismiss error' })).toBeNull()
  })

  it('leaves a failed load to the bottom bar while the unit is unreachable', () => {
    dashboardSocket.isConnected.mockReturnValue(false)
    useParameters.setState({ groups, error: 'Cannot reach the vision unit', errorSource: 'load' })
    render(<App />)

    expect(screen.queryByRole('alert')).toBeNull()
    expect(within(screen.getByRole('contentinfo')).getByText('Connecting…')).toBeTruthy()
  })

  it('says in the bottom bar that the unit is connected', () => {
    render(<App />)
    expect(within(screen.getByRole('contentinfo')).getByText('Connected')).toBeTruthy()
  })

  it('lands on the overview, with no stage selected and no save bar', () => {
    useParameters.setState({ groups })
    render(<App />)

    expect(screen.getByRole('button', { name: 'Overview' }).getAttribute('aria-current')).toBe('page')
    expect(useParameters.getState().selectedGroupId).toBeNull()
    expect(screen.queryByRole('button', { name: /^Save/ })).toBeNull()
    expect(window.location.search).toBe('')
  })

  it('opens the exporter the URL names, and keeps the page in the URL', () => {
    visit('/?exporter=api')
    useParameters.setState({ groups })
    render(<App />)
    expect(screen.getByRole('heading', { name: 'API' })).toBeTruthy()

    act(() => useCalibration.setState({ targets: [{ id: 'center', kind: 'camera' }] }))
    fireEvent.click(screen.getByRole('button', { name: 'Center camera' }))
    expect(window.location.search).toBe('?calibration=center')
    expect(useNavigation.getState()).toMatchObject({ page: 'calibration', calibrationId: 'center' })
  })

  it("opens an exporter without a page of its own on the exporters' page: its status and outputs", () => {
    render(<App />)
    act(() => useStatus.setState({ snapshot: { exporters: [{ id: 'recorder', name: 'Recorder', status: { level: 'ok', detail: 'Recording' } }] } }))

    fireEvent.click(screen.getByRole('button', { name: /^Recorder/ }))

    expect(window.location.search).toBe('?exporter=recorder')
    expect(screen.getByRole('heading', { name: 'Recorder' })).toBeTruthy()
    expect(screen.getByText('Recording')).toBeTruthy()
    expect(screen.getByRole('row', { name: /Stereo pairs/ }).textContent).toContain('at most 2 Hz')
  })

  it('keeps the videos playing between the overview and a stage, which show the same previews', () => {
    useParameters.setState({ groups })
    render(<App />)
    const channels = () => dashboardSocket.channel.mock.results.map((result) => result.value)
    const opened = channels().length
    const previews = () => screen.getByRole('region', { name: 'Previews' })
    const shown = previews()

    fireEvent.click(screen.getByRole('button', { name: 'Match' }))
    expect(screen.getByRole('heading', { name: 'Match' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Overview' }))

    expect(previews()).toBe(shown)
    expect(channels()).toHaveLength(opened)
    expect(channels().filter((channel) => channel.leave.mock.calls.length > 0)).toEqual([])
  })

  describe("a camera's calibration and position", () => {
    const targets = [
      { id: 'stereo', kind: 'stereo' },
      { id: 'center', kind: 'camera' },
      { id: 'center-pose', kind: 'pose' }
    ]
    const camera = (name) => within(screen.getByRole('list', { name }))
    const previews = () => screen.getByRole('region', { name: 'Previews' })
    // The channels of the previews' frames, by topic, each with whether it was left.
    const frameChannels = () =>
      dashboardSocket.channel.mock.calls
        .map(([topic], index) => ({ topic, left: dashboardSocket.channel.mock.results[index].value.leave.mock.calls.length > 0 }))
        .filter(({ topic }) => /^(preview|video):/.test(topic))

    beforeEach(() => {
      useParameters.setState({ groups })
      useCalibration.setState({ targets })
    })

    it('shows the page in a card beside the previews', () => {
      visit('/?calibration=center-pose')
      render(<App />)

      const panel = screen.getByText('Waiting for the vision unit…').closest('[data-scroll="panel"]')
      expect(panel).not.toBeNull()
      expect(panel.parentElement.className.split(' ')).toContain('ovcs-card')
      expect(panel.parentElement.nextElementSibling.contains(previews())).toBe(true)
    })

    it("keeps the videos playing from a camera's settings to its calibration, its position and the overview", () => {
      render(<App />)
      const shown = previews()
      const opened = frameChannels().length

      fireEvent.click(camera('Stereo cameras').getByRole('button', { name: 'Settings' }))
      expect(window.location.search).toBe('?box=cameras')
      fireEvent.click(camera('Stereo cameras').getByRole('button', { name: 'Calibration' }))
      expect(window.location.search).toBe('?calibration=stereo')
      expect(previews()).toBe(shown)
      fireEvent.click(camera('Center camera').getByRole('button', { name: /^Position/ }))
      expect(window.location.search).toBe('?calibration=center-pose')
      expect(previews()).toBe(shown)
      fireEvent.click(screen.getByRole('button', { name: 'Overview' }))

      expect(previews()).toBe(shown)
      expect(frameChannels()).toHaveLength(opened)
      expect(frameChannels().filter((channel) => channel.left)).toEqual([])
    })

    it("stops the previews while a capture shows the cameras, which join their frames' channels", () => {
      const stereo = {
        id: 'stereo',
        kind: 'stereo',
        source: 'none',
        cameras: ['left', 'right'].map((name) => ({ name, file: `${name}.yaml`, fx: null, fy: null, cx: null, cy: null, distortion: null, yaml: null }))
      }
      const capture = {
        phase: 'capturing',
        calibration: 'stereo',
        board: { columns: 8, rows: 6, squareMm: 25 },
        samples: 0,
        progress: { x: 0, y: 0, size: 0, skew: 0 },
        goodEnough: false,
        detection: null,
        result: null,
        error: null
      }
      visit('/?calibration=stereo')
      render(<App />)
      act(() => useCalibration.setState({ calibrations: { stereo }, session: capture }))

      const open = frameChannels().filter((channel) => !channel.left)
      expect(open.length).toBeGreaterThan(0)
      expect(new Set(open.map((channel) => channel.topic)).size).toBe(open.length)
      expect(screen.queryByRole('region', { name: 'Previews' })).toBeNull()

      act(() => useCalibration.setState({ session: { ...capture, phase: 'idle' } }))
      expect(previews()).toBeTruthy()
    })
  })

  it("lets the previews fill the main's height from lg, on the overview, beside a stage and beside a calibration", () => {
    useParameters.setState({ groups })
    render(<App />)
    // Each box between the main and the previews grows into the main's height, as the previews do in it.
    const growing = () => {
      const boxes = []
      for (let box = screen.getByRole('region', { name: 'Previews' }); box.tagName !== 'MAIN'; box = box.parentElement) boxes.push(box)
      return boxes.map((box) => box.className.split(' ').includes('lg:flex-1'))
    }

    expect(growing().every(Boolean)).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Match' }))
    expect(growing().every(Boolean)).toBe(true)
    act(() => useNavigation.getState().openCalibration('center'))
    expect(growing().every(Boolean)).toBe(true)
  })

  it('opens a stage from the menu on the pipeline page, then leaves it for another page', () => {
    useParameters.setState({ groups })
    render(<App />)

    fireEvent.click(screen.getByRole('button', { name: 'Match' }))
    expect(window.location.search).toBe('?box=stereo.match')
    expect(screen.getByRole('heading', { name: 'Match' })).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: /^API/ }))
    expect(window.location.search).toBe('?exporter=api')
    expect(screen.getByRole('button', { name: 'Match' }).getAttribute('aria-current')).toBeNull()
  })

  it('keeps the menu and the bars, and says the page cannot be shown, when a status it cannot read comes', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    render(<App />)

    // A rows check without its bands, as a firmware newer than this page could push.
    act(() => useStatus.setState({ snapshot: { pair: { rows: { level: 'ok', issues: [] } } } }))

    expect(within(screen.getByRole('main')).getByRole('alert').textContent).toContain('This page cannot be shown')
    expect(screen.getByRole('navigation', { name: 'Vision unit' })).toBeTruthy()
    expect(within(screen.getByRole('contentinfo')).getByText('Connected')).toBeTruthy()
    expect(screen.getByRole('banner')).toBeTruthy()
    vi.restoreAllMocks()
  })

  it('shows the page again once another page is opened after one that could not be shown', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    render(<App />)
    act(() => useStatus.setState({ snapshot: { pair: { rows: { level: 'ok', issues: [] } } } }))

    fireEvent.click(screen.getByRole('button', { name: /^API/ }))

    expect(within(screen.getByRole('main')).queryByRole('alert')).toBeNull()
    expect(screen.getByRole('heading', { name: 'API' })).toBeTruthy()
    vi.restoreAllMocks()
  })

  describe('with a firmware uploaded under the open page', () => {
    const firmware = (revision) => service.request.mockImplementation(async (path) => {
        if (path !== 'firmware') throw new Error('Cannot reach the vision unit')
        return { data: { attributes: { revision } } }
      })
    const join = (joins) => act(async () => useStatus.setState({ joins }))

    it('offers to reload once the unit answers another revision than at first', async () => {
      firmware('1e13961')
      render(<App />)
      await join(1)
      expect(screen.queryByRole('button', { name: 'Reload' })).toBeNull()

      firmware('26e78c0')
      await join(2)

      expect(within(screen.getByRole('banner')).getByRole('status').textContent).toContain('another firmware')
      expect(screen.getByRole('button', { name: 'Reload' })).toBeTruthy()
    })

    it('offers nothing while the unit comes back with the same revision', async () => {
      firmware('1e13961')
      render(<App />)
      await join(1)
      await join(2)

      expect(screen.queryByRole('button', { name: 'Reload' })).toBeNull()
    })
  })
})
