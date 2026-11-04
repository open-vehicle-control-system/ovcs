import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import CalibrationPage from '../CalibrationPage.jsx'
import { useCalibration } from '../../stores/calibration.js'
import { useStatus } from '../../stores/status.js'
import { downloadYaml } from '../../services/calibration.js'
import { dashboardSocket } from '../../services/socket.js'

const { handlers } = vi.hoisted(() => ({ handlers: {} }))

vi.mock('../../services/socket.js', () => ({
  dashboardSocket: {
    channel: vi.fn((topic) => ({
      on: (event, handler) => {
        handlers[`${topic}/${event}`] = handler
      },
      join: () => ({ receive() { return this } }),
      push: () => ({ receive() { return this } }),
      off: () => {},
      leave: () => {}
    }))
  }
}))

vi.mock('../../services/calibration.js', async (original) => ({ ...(await original()), downloadYaml: vi.fn() }))

const side = (fx, yaml) => ({
  imageWidth: 1280,
  imageHeight: 720,
  fx,
  fy: fx + 1,
  cx: 640.25,
  cy: 360.5,
  distortion: [-0.1234, 0.0567, 0.0001, -0.0002, 0],
  yaml
})

const stored = {
  source: 'stored',
  storedAt: '2026-10-30T14:05:00Z',
  canReset: true,
  prefix: 'ovcs_mini',
  baselineM: 0.0601,
  rectifiedFx: 905.67,
  left: side(912.34, 'left in use'),
  right: side(915.5, 'right in use')
}

const builtIn = { ...stored, source: 'builtIn', storedAt: null, canReset: false }

const blank = { imageWidth: null, imageHeight: null, fx: null, fy: null, cx: null, cy: null, distortion: null, yaml: null }
const none = {
  source: 'none',
  storedAt: null,
  canReset: false,
  prefix: 'ovcs_mini',
  baselineM: null,
  rectifiedFx: null,
  left: blank,
  right: blank
}

const board = { columns: 8, rows: 6, squareMm: 25 }
const progress = { x: 0.42, y: 0.8, size: 0.25, skew: 1 }

const session = (attributes) => ({
  phase: 'idle',
  board: null,
  samples: 0,
  progress: { x: 0, y: 0, size: 0, skew: 0 },
  goodEnough: false,
  detection: null,
  result: null,
  error: null,
  ...attributes
})

const capturing = (attributes) => session({ phase: 'capturing', board, samples: 12, progress, ...attributes })

const result = {
  leftRmsPx: 0.31,
  rightRmsPx: 0.87,
  stereoRmsPx: 2.4,
  baselineM: 0.0598,
  fxPx: 910.12,
  samples: 40,
  left: { yaml: 'left solved' },
  right: { yaml: 'right solved' }
}

const initialStatus = useStatus.getState()

describe('CalibrationPage', () => {
  let actions

  beforeEach(() => {
    for (const key of Object.keys(handlers)) delete handlers[key]
    dashboardSocket.channel.mockClear()
    downloadYaml.mockClear()
    localStorage.clear()
    URL.createObjectURL = vi.fn(() => 'blob:frame')
    URL.revokeObjectURL = vi.fn()
    actions = {
      unlisten: vi.fn(),
      start: vi.fn(),
      cancel: vi.fn(),
      solve: vi.fn(),
      apply: vi.fn(),
      reset: vi.fn(),
      dismissError: vi.fn()
    }
    useStatus.setState({ ...initialStatus, snapshot: null })
    useCalibration.setState({
      session: null,
      inUse: null,
      error: null,
      busy: false,
      unavailable: false,
      listen: vi.fn(() => actions.unlisten),
      ...actions
    })
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    delete URL.createObjectURL
    delete URL.revokeObjectURL
  })

  const show = (state) => {
    useCalibration.setState(state)
    return render(<CalibrationPage />)
  }

  const inUseCard = () => screen.getByRole('region', { name: 'In use' })
  const button = (name) => screen.getByRole('button', { name })
  const query = (name) => screen.queryByRole('button', { name })

  it('listens to the calibration channel while mounted', () => {
    const { unmount } = show({ session: session() })

    expect(useCalibration.getState().listen).toHaveBeenCalledWith(dashboardSocket)
    expect(actions.unlisten).not.toHaveBeenCalled()
    unmount()
    expect(actions.unlisten).toHaveBeenCalledTimes(1)
  })

  describe('in use', () => {
    it('names a built-in calibration, and shows fx and the baseline in mm', () => {
      show({ inUse: builtIn, session: session() })

      const card = inUseCard()
      expect(card.textContent).toContain('Built-in')
      expect(card.textContent).toContain('912.3')
      expect(card.textContent).toContain('60.1 mm')
      expect(card.textContent).toContain('1280 × 720')
      expect(within(card).getAllByRole('row')).toHaveLength(3)
    })

    it('names a calibration stored on the unit, with its date', () => {
      show({ inUse: stored, session: session() })

      expect(inUseCard().textContent).toContain('Stored on the unit')
      expect(inUseCard().textContent).toContain('2026')
    })

    it('names a unit without a calibration, with nothing to download', () => {
      show({ inUse: none, session: session() })

      expect(inUseCard().textContent).toContain('None')
      expect(within(inUseCard()).queryByRole('button', { name: 'Download the calibration in use' })).toBeNull()
    })

    it("downloads both cameras' YAMLs under the unit's prefix", () => {
      show({ inUse: stored, session: session() })

      fireEvent.click(button('Download the calibration in use'))

      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_left.yaml', 'left in use')
      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_right.yaml', 'right in use')
    })

    it('returns to the built-in calibration only when it can, and once confirmed', () => {
      const confirm = vi.spyOn(window, 'confirm').mockReturnValueOnce(false).mockReturnValueOnce(true)
      const { unmount } = show({ inUse: builtIn, session: session() })
      expect(query('Return to built-in')).toBeNull()
      unmount()

      show({ inUse: stored, session: session() })
      fireEvent.click(button('Return to built-in'))
      expect(confirm).toHaveBeenCalledTimes(1)
      expect(actions.reset).not.toHaveBeenCalled()

      fireEvent.click(button('Return to built-in'))
      expect(actions.reset).toHaveBeenCalledTimes(1)
    })

    it('offers to return to built-in with a side stored alone, the built-in calibration in force', () => {
      show({ inUse: { ...builtIn, canReset: true }, session: session() })

      expect(inUseCard().textContent).toContain('Built-in')
      expect(button('Return to built-in')).toBeTruthy()
    })

    it('does not return to built-in while a calibration is being applied', () => {
      show({ inUse: stored, session: session({ phase: 'applying', board, result }) })

      expect(button('Return to built-in').disabled).toBe(true)
    })
  })

  describe('idle', () => {
    it('asks for the board in inner corners, prefilled with the default board, and starts with it', () => {
      show({ inUse: stored, session: session() })

      expect(screen.getByLabelText('Inner corners (columns)').value).toBe('8')
      expect(screen.getByLabelText('Inner corners (rows)').value).toBe('6')
      expect(screen.getByLabelText('Square size (mm)').value).toBe('25')

      fireEvent.click(button('Start'))
      expect(actions.start).toHaveBeenCalledWith({ columns: 8, rows: 6, squareMm: 25 })
    })

    it('starts with the board entered, and remembers it', () => {
      const { unmount } = show({ inUse: stored, session: session() })

      fireEvent.change(screen.getByLabelText('Inner corners (columns)'), { target: { value: '9' } })
      fireEvent.change(screen.getByLabelText('Square size (mm)'), { target: { value: '30.5' } })
      fireEvent.click(button('Start'))
      expect(actions.start).toHaveBeenCalledWith({ columns: 9, rows: 6, squareMm: 30.5 })
      unmount()

      show({ inUse: stored, session: session() })
      expect(screen.getByLabelText('Inner corners (columns)').value).toBe('9')
    })

    const rule = 'Columns and rows must be different whole numbers of 2 or more; the square size must be above 0.'

    it.each([
      ['an empty count', 'Inner corners (rows)', ''],
      ['no corners', 'Inner corners (columns)', '0'],
      ['a negative count', 'Inner corners (rows)', '-6'],
      ['a fractional count', 'Inner corners (columns)', '8.5'],
      ['as many columns as rows', 'Inner corners (columns)', '6'],
      ['a square of 0 mm', 'Square size (mm)', '0'],
      ['a negative square size', 'Square size (mm)', '-25']
    ])('does not start with %s, and says why', (_case, label, entered) => {
      show({ inUse: stored, session: session() })
      expect(screen.queryByText(rule)).toBeNull()

      fireEvent.change(screen.getByLabelText(label), { target: { value: entered } })
      expect(button('Start').disabled).toBe(true)
      expect(button('Start').getAttribute('aria-describedby')).toBe(screen.getByText(rule).id)

      fireEvent.click(button('Start'))
      expect(actions.start).not.toHaveBeenCalled()
    })
  })

  describe('capturing', () => {
    const coverage = () => screen.getByRole('group', { name: 'Coverage' })

    it('shows both previews, the four coverage bars and the sample count', () => {
      show({ inUse: stored, session: capturing() })

      const topics = dashboardSocket.channel.mock.calls.map(([topic]) => topic)
      expect(topics).toContain('preview:left')
      expect(topics).toContain('preview:right')

      const bars = within(coverage()).getAllByRole('progressbar')
      expect(bars.map((bar) => bar.getAttribute('aria-label'))).toEqual(['X', 'Y', 'Size', 'Skew'])
      expect(bars.map((bar) => bar.getAttribute('aria-valuenow'))).toEqual(['42', '80', '25', '100'])
      expect(coverage().textContent).toContain('42 %')
      expect(coverage().textContent).toContain('100 %')
      expect(screen.getByText('Samples').parentElement.textContent).toContain('12')
    })

    it('calibrates only once the samples are good enough, and cancels', () => {
      show({ inUse: stored, session: capturing() })
      expect(button('Calibrate').disabled).toBe(true)

      act(() => useCalibration.setState({ session: capturing({ goodEnough: true }) }))
      fireEvent.click(button('Calibrate'))
      expect(actions.solve).toHaveBeenCalledTimes(1)

      fireEvent.click(button('Cancel'))
      expect(actions.cancel).toHaveBeenCalledTimes(1)
    })

    it('names the corners it looks for while neither camera sees the board', () => {
      show({ inUse: stored, session: capturing({ board: { columns: 9, rows: 7, squareMm: 25 } }) })
      expect(screen.getByText(/Looking for a board with 9 × 7 inner corners/)).toBeTruthy()

      act(() => useCalibration.setState({ session: capturing({ detection: { left: null, right: null, sample: false } }) }))
      expect(screen.getByText(/Looking for a board with 8 × 6 inner corners/)).toBeTruthy()

      act(() =>
        useCalibration.setState({ session: capturing({ detection: { left: [[0.1, 0.2]], right: null, sample: false } }) })
      )
      expect(screen.queryByText(/Looking for a board/)).toBeNull()
    })

    it("draws each camera's corners over its frame, in one colour once the pair became a sample", () => {
      show({ inUse: stored, session: capturing() })
      const figure = (stream) => screen.getByText(stream, { selector: 'figcaption span' }).closest('figure')
      for (const stream of ['left', 'right']) {
        act(() => handlers[`preview:${stream}/frame`](new Uint8Array([1]).buffer))
        const image = within(figure(stream)).getByRole('img', { name: `${stream} preview` })
        Object.defineProperties(image, { naturalWidth: { value: 640 }, naturalHeight: { value: 480 } })
        fireEvent.load(image)
      }

      const corners = [[0.1, 0.2], [0.2, 0.2], [0.1, 0.3], [0.2, 0.3]]
      act(() => useCalibration.setState({ session: capturing({ detection: { left: corners, right: null, sample: false } }) }))
      const left = figure('left').querySelector('svg[data-corners]')
      expect(left.getAttribute('viewBox')).toBe('0 0 640 480')
      expect(left.querySelectorAll('circle')).toHaveLength(4)
      expect(left.querySelector('polyline').getAttribute('points')).toBe('64,96 128,96 64,144 128,144')
      const detected = left.getAttribute('class')
      expect(figure('right').querySelectorAll('svg[data-corners] circle')).toHaveLength(0)

      act(() => useCalibration.setState({ session: capturing({ detection: { left: corners, right: corners, sample: true } }) }))
      expect(figure('left').querySelector('svg[data-corners]').getAttribute('class')).not.toBe(detected)
      expect(figure('right').querySelectorAll('svg[data-corners] circle')).toHaveLength(4)
    })

    it("shows the unit's refusal of a solve", () => {
      show({ inUse: stored, session: capturing({ error: 'the solve failed; the log says why' }) })

      expect(screen.getByRole('alert').textContent).toContain('the solve failed; the log says why')
    })
  })

  it('shows a solve in progress, which can be cancelled', () => {
    show({ inUse: stored, session: session({ phase: 'solving', board, samples: 40 }) })

    expect(screen.getByText(/Calibrating from 40 samples/)).toBeTruthy()
    fireEvent.click(button('Cancel'))
    expect(actions.cancel).toHaveBeenCalledTimes(1)
  })

  describe('solved', () => {
    const resultCard = () => screen.getByRole('region', { name: 'Result' })
    const rms = (label) => within(resultCard()).getByText(label).closest('tr')

    it('reads the reprojection errors in colour and words: good under 0.5 px, fair to 2 px, poor over', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result }) })

      expect(rms('Left RMS').querySelector('.ovcs-status--ok').textContent).toContain('0.31 px, good')
      expect(rms('Right RMS').querySelector('.ovcs-status--warn').textContent).toContain('0.87 px, fair')
      expect(rms('Stereo RMS').querySelector('.ovcs-status--error').textContent).toContain('2.40 px, poor')
    })

    it('reads 0.5 and 2 px as fair', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, result: { ...result, leftRmsPx: 0.5, rightRmsPx: 2 } }) })

      expect(rms('Left RMS').textContent).toContain('fair')
      expect(rms('Right RMS').textContent).toContain('fair')
    })

    it('shows a dash for a focal length and baseline in use the unit does not have', () => {
      show({ inUse: none, session: session({ phase: 'solved', board, result }) })

      expect(rms('focal length (rectified)').querySelectorAll('td')[1].textContent).toBe('–')
      expect(rms('Baseline').querySelectorAll('td')[1].textContent).toBe('–')
    })

    it('shows the baseline and the rectified focal length next to the ones in use', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result }) })

      expect(rms('Baseline').textContent).toContain('59.8 mm')
      expect(rms('Baseline').textContent).toContain('60.1 mm')
      expect(rms('focal length (rectified)').textContent).toContain('910.1')
      expect(rms('focal length (rectified)').textContent).toContain('905.7')
    })

    it('applies, downloads both YAMLs and discards', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result }) })

      fireEvent.click(button('Apply'))
      expect(actions.apply).toHaveBeenCalledTimes(1)

      fireEvent.click(button('Download the solved calibration'))
      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_left.yaml', 'left solved')
      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_right.yaml', 'right solved')

      fireEvent.click(button('Discard'))
      expect(actions.cancel).toHaveBeenCalledTimes(1)
    })

    it("shows the unit's refusal of an apply", () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, result, error: 'the apply failed; the log says why' }) })

      expect(screen.getByRole('alert').textContent).toContain('the apply failed; the log says why')
      expect(button('Apply')).toBeTruthy()
    })

    it('shows an apply in progress, with nothing to apply or discard', () => {
      show({ inUse: stored, session: session({ phase: 'applying', board, result }) })

      expect(within(resultCard()).getByText(/Applying/)).toBeTruthy()
      expect(query('Apply')).toBeNull()
      expect(query('Discard')).toBeNull()
    })
  })

  it('shows a refused action until dismissed', () => {
    show({ inUse: stored, session: session(), error: 'a calibration session is already running' })

    expect(screen.getByRole('alert').textContent).toContain('a calibration session is already running')
    fireEvent.click(button('Dismiss error'))
    expect(actions.dismissError).toHaveBeenCalledTimes(1)
  })

  it('explains that an uncalibrated unit starts its depth once a calibration is applied', () => {
    useStatus.setState({ snapshot: { calibrated: false } })
    show({ inUse: none, session: session() })

    expect(screen.getByText(/depth starts once a calibration is applied/)).toBeTruthy()
  })

  it('says so on a unit without stereo cameras', () => {
    show({ unavailable: true })

    expect(screen.getByText(/no stereo cameras/)).toBeTruthy()
    expect(query('Start')).toBeNull()
  })
})
