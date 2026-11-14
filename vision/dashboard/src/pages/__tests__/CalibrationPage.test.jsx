import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import CalibrationPage from '../CalibrationPage.jsx'
import { useCalibration } from '../../stores/calibration.js'
import { useStatus } from '../../stores/status.js'
import { useNavigation } from '../../stores/navigation.js'
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
      onError: (handler) => {
        handlers[`${topic}/error`] = handler
      },
      leave: () => {}
    }))
  }
}))

vi.mock('../../services/calibration.js', async (original) => ({ ...(await original()), downloadYaml: vi.fn() }))

const side = (name, fx, yaml) => ({
  name,
  file: `ovcs_mini_${name}.yaml`,
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
  id: 'ovcs_mini',
  kind: 'stereo',
  source: 'stored',
  storedAt: '2026-10-30T14:05:00Z',
  canReset: true,
  baselineM: 0.0601,
  rectifiedFx: 905.67,
  cameras: [side('left', 912.34, 'left in use'), side('right', 915.5, 'right in use')]
}

const builtIn = { ...stored, source: 'builtIn', storedAt: null, canReset: false }

const blank = (name) => ({
  name,
  file: `ovcs_mini_${name}.yaml`,
  imageWidth: null,
  imageHeight: null,
  fx: null,
  fy: null,
  cx: null,
  cy: null,
  distortion: null,
  yaml: null
})
const none = {
  id: 'ovcs_mini',
  kind: 'stereo',
  source: 'none',
  storedAt: null,
  canReset: false,
  baselineM: null,
  rectifiedFx: null,
  cameras: [blank('left'), blank('right')]
}

// A camera of its own, beside the stereo pair.
const center = {
  id: 'center',
  kind: 'camera',
  source: 'builtIn',
  storedAt: null,
  canReset: false,
  baselineM: null,
  rectifiedFx: null,
  cameras: [{ ...side('center', 880.5, 'center in use'), file: 'center.yaml' }]
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

// A detection as the unit pushes it: each camera's corners, `null` where it does not see the board.
const detection = (views, sample = false) => ({
  views: Object.entries(views).map(([camera, points]) => ({ camera, points })),
  sample
})

const result = {
  imageWidth: 1280,
  imageHeight: 720,
  cameras: [
    { name: 'left', file: 'ovcs_mini_left.yaml', rmsPx: 0.31, yaml: 'left solved' },
    { name: 'right', file: 'ovcs_mini_right.yaml', rmsPx: 0.87, yaml: 'right solved' }
  ],
  stereoRmsPx: 2.4,
  baselineM: 0.0598,
  fxPx: 910.12,
  samples: 40
}

const kept = (attributes) => ({
  id: '7',
  name: '2026-11-14 00:28',
  origin: 'dashboard',
  createdAt: '2026-11-14T00:28:11Z',
  inForce: false,
  board: { columns: 8, rows: 6, squareMm: 30 },
  samples: 62,
  stereoRmsPx: 0.34,
  baselineM: 0.198,
  cameras: [
    { name: 'left', rmsPx: 0.21, file: 'ovcs_mini_left.yaml', yaml: 'left kept' },
    { name: 'right', rmsPx: 0.3, file: 'ovcs_mini_right.yaml', yaml: 'right kept' }
  ],
  ...attributes
})

const found = kept({
  id: '3',
  name: 'Bench',
  origin: 'imported',
  stereoRmsPx: null,
  cameras: [
    { name: 'left', rmsPx: null, file: 'ovcs_mini_left.yaml', yaml: 'left found' },
    { name: 'right', rmsPx: null, file: 'ovcs_mini_right.yaml', yaml: 'right found' }
  ]
})

// As the page writes a time.
const stamp = (iso) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso))

const BASELINE = 'Baseline (distance between the cameras)'

// A figure's value, line by line.
const lines = (value) => (value.children.length > 0 ? [...value.children].map((line) => line.textContent) : [value.textContent])

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
      useSaved: vi.fn(),
      renameSaved: vi.fn(),
      deleteSaved: vi.fn(),
      loadSaved: vi.fn(),
      dismissError: vi.fn()
    }
    useStatus.setState({ ...initialStatus, snapshot: null })
    useNavigation.setState({ page: 'calibration', calibrationId: null })
    useCalibration.setState({
      session: null,
      calibrations: {},
      saved: {},
      selected: null,
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

  // `inUse` is the calibration picked, the only one the unit has unless `calibrations` lists more.
  const show = ({ inUse, closed = false, ...state }) => {
    const picked = inUse ? { calibrations: { [inUse.id]: inUse }, selected: inUse.id } : {}
    useCalibration.setState({ ...picked, ...state })
    const page = render(<CalibrationPage />)
    // The steps are in a dialog, which an idle session opens from the page's button.
    const open = closed ? null : screen.queryByRole('button', { name: /^Calibrate( again)?$/ })
    if (open) fireEvent.click(open)
    return page
  }

  const inUseCard = () => screen.getByRole('region', { name: /shipped with the firmware|Calibrated on this unit|Not calibrated/ })
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
    const labels = () => [...inUseCard().querySelectorAll('dt')].map((label) => label.textContent)
    const values = () => [...inUseCard().querySelectorAll('dd')].map((value) => value.textContent)
    const table = () => within(inUseCard()).getByRole('table', { name: 'Camera parameters, in pixels' })
    const row = (name) => within(table()).getByRole('row', { name })
    const PARAMETERS = ['Focal x (fx)', 'Focal y (fy)', 'Centre x (cx)', 'Centre y (cy)', 'Distortion', 'k1', 'k2', 'p1', 'p2', 'k3']

    it('sums up the image size and the lens distortion, then for a pair its baseline, and no focal length', () => {
      const { unmount } = show({ inUse: stored, session: session() })
      expect(labels()).toEqual(['Image size', 'Lens distortion', BASELINE])
      unmount()

      show({ inUse: center, session: session() })
      expect(labels()).toEqual(['Image size', 'Lens distortion'])
    })

    it('names a built-in calibration, with the baseline in mm', () => {
      show({ inUse: builtIn, session: session() })

      const card = inUseCard()
      expect(within(card).getByRole('heading').textContent).toBe('Using the calibration shipped with the firmware')
      expect(card.textContent).toContain('No calibration was made on this unit.')
      expect(values()).toEqual(['1280 × 720 px', 'Corrected', '60.1 mm'])
      expect(card.textContent).not.toContain('Focal length')
    })

    it("lists a pair's parameters under Left and Right, one distortion coefficient a row, in the font of every figure", () => {
      show({ inUse: builtIn, session: session() })

      expect(within(table()).getAllByRole('columnheader').map((header) => header.textContent)).toEqual(['Left', 'Right'])
      expect(within(table()).getAllByRole('rowheader').map((header) => header.textContent)).toEqual(PARAMETERS)
      expect(row(/^Focal x/).textContent).toBe('Focal x (fx)912.3915.5')
      expect(row(/^k1/).textContent).toBe('k1-0.1234-0.1234')
      expect(row(/^p2/).textContent).toBe('p2-0.0002-0.0002')
      expect(row(/^k3/).textContent).toBe('k30.00000.0000')
      expect(inUseCard().querySelector('.font-mono')).toBeNull()
    })

    it("lists a camera's parameters in a single column, under no header", () => {
      show({ inUse: center, session: session() })

      expect(within(table()).queryAllByRole('columnheader')).toEqual([])
      expect(within(table()).getAllByRole('rowheader').map((header) => header.textContent)).toEqual(PARAMETERS)
      expect(row(/^Focal x/).textContent).toBe('Focal x (fx)880.5')
      expect(row(/^k2/).textContent).toBe('k20.0567')
    })

    it('names a calibration stored on the unit without a date, then the one kept it uses, by name and when it was made', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })

      expect(within(inUseCard()).getByRole('heading').textContent).toBe('Calibrated on this unit')
      expect(inUseCard().textContent).toContain(`2026-11-14 00:28 · made ${stamp('2026-11-14T00:28:11Z')}`)
      expect(inUseCard().textContent).not.toContain(stamp(stored.storedAt))
    })

    it('dates a stored calibration by its file while no calibration kept is in use', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [found] }, session: session() })

      expect(within(inUseCard()).getByRole('heading').textContent).toBe('Calibrated on this unit')
      expect(inUseCard().textContent).toContain(stamp(stored.storedAt))
    })

    it("names no calibration kept while the firmware's is in use", () => {
      show({ inUse: builtIn, closed: true, saved: { ovcs_mini: [kept({ inForce: true })] }, session: session() })

      expect(inUseCard().textContent).not.toContain('2026-11-14 00:28')
      expect(inUseCard().textContent).not.toContain(stamp('2026-11-14T00:28:11Z'))
    })

    it('offers Download once: on the calibration kept in use, beside the heading otherwise', () => {
      const { unmount } = show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })
      expect(query('Download the calibration the unit uses')).toBeNull()
      expect(button('Download 2026-11-14 00:28')).toBeTruthy()
      unmount()

      show({ inUse: builtIn, closed: true, saved: { ovcs_mini: [found] }, session: session() })
      expect(button('Download the calibration the unit uses')).toBeTruthy()
    })

    it('offers Download beside the heading when the calibration kept in use has no files', () => {
      const fileless = kept({ inForce: true, cameras: [{ name: 'left', rmsPx: 0.2 }, { name: 'right', rmsPx: 0.3 }] })
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [fileless] }, session: session() })

      expect(query('Download 2026-11-14 00:28')).toBeNull()
      expect(button('Download the calibration the unit uses')).toBeTruthy()
    })

    it('names a unit without a calibration, with nothing to download', () => {
      show({ inUse: none, session: session() })

      expect(within(inUseCard()).getByRole('heading').textContent).toBe('Not calibrated')
      expect(inUseCard().textContent).toContain('Depth stays off until a calibration is made.')
      expect(labels()).toEqual(['Image size', 'Lens distortion', BASELINE])
      expect(values()).toEqual(['–', '–', '–'])
      expect(row(/^Focal x/).textContent).toBe('Focal x (fx)––')
      expect(row(/^k1/).textContent).toBe('k1––')
      expect(within(inUseCard()).queryByRole('button', { name: 'Download the calibration the unit uses' })).toBeNull()
    })

    it("downloads both cameras' YAMLs under the unit's prefix", () => {
      show({ inUse: stored, session: session() })

      fireEvent.click(button('Download the calibration the unit uses'))

      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_left.yaml', 'left in use')
      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_right.yaml', 'right in use')
    })
  })

  describe('the calibrations kept', () => {
    const keptCard = () => screen.getByRole('region', { name: 'Calibrations kept on the unit' })
    const row = (name) => within(keptCard()).getByRole('listitem', { name })

    it('reads the list of the calibration shown', () => {
      show({ inUse: stored, session: session() })
      expect(actions.loadSaved).not.toHaveBeenCalled()

      act(() => useNavigation.setState({ calibrationId: 'ovcs_mini' }))
      expect(useCalibration.getState().selected).toBe('ovcs_mini')
    })

    it('lists each calibration with when and where it was made, its errors and its baseline, the one in use marked', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })

      const first = row(/2026-11-14 00:28/)
      expect([...first.querySelectorAll('dt')].map((label) => label.textContent)).toEqual(['Reprojection error', BASELINE])
      expect(first.textContent).toContain(`Made ${stamp('2026-11-14T00:28:11Z')} · on this page`)
      expect(lines(first.querySelector('dd'))).toEqual(['left 0.21 px', 'right 0.30 px', 'pair 0.34 px'])
      expect(first.textContent).toContain('198.0 mm')
      expect(within(first).getByText('In use')).toBeTruthy()
      expect(within(first).queryByRole('button', { name: /^Use / })).toBeNull()

      const second = row(/Bench/)
      expect(second.textContent).toContain('· outside this page')
      expect(second.textContent).not.toContain('Found on the unit')
      expect([...second.querySelectorAll('dt')].map((label) => label.textContent)).toEqual([BASELINE])
      expect(second.textContent).not.toContain('–')
      expect(within(second).queryByText('In use')).toBeNull()
    })

    it('gives each calibration kept its actions in small buttons, Rename among them', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })

      const actions = within(row(/Bench/)).getAllByRole('button')
      expect(actions.map((action) => action.getAttribute('aria-label'))).toEqual(['Use Bench', 'Download Bench', 'Rename Bench', 'Delete Bench'])
      expect(actions.map((action) => action.textContent)).toEqual(['Use', 'Download', 'Rename', 'Delete'])
      for (const action of actions) expect(action.className).toContain('text-xs')
      expect(within(row(/2026-11-14 00:28/)).getAllByRole('button').map((action) => action.textContent)).toEqual(['Download', 'Rename', 'Delete'])
    })

    it("says what the firmware's entry is, with a small Use button", () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true })] }, session: session() })

      const firmware = row(/Shipped with the firmware/)
      expect(firmware.textContent).toContain('The calibration the firmware was built with')
      expect(button('Use the calibration shipped with the firmware').className).toContain('text-xs')
    })

    // Answers the question the page asks with its button `choice`, and gives what it asked.
    const answer = async (choice) => {
      const dialog = screen.getByRole('alertdialog')
      const question = dialog.textContent
      await act(async () => fireEvent.click(within(dialog).getByRole('button', { name: choice })))
      return question
    }

    it('puts another calibration in use, and deletes one once confirmed in its own dialog', async () => {
      const confirm = vi.spyOn(window, 'confirm')
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })

      fireEvent.click(button('Use Bench'))
      expect(actions.useSaved).toHaveBeenCalledWith('3')

      fireEvent.click(button('Delete Bench'))
      expect(await answer('Cancel')).toContain('Delete the calibration "Bench"?')
      expect(actions.deleteSaved).not.toHaveBeenCalled()

      fireEvent.click(button('Delete Bench'))
      expect(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Delete' }).className).toContain('text-ovcs-error-text')
      await answer('Delete')
      expect(actions.deleteSaved).toHaveBeenCalledWith('3')
      expect(confirm).not.toHaveBeenCalled()
    })

    it("explains where a calibration was made once, beside the list's heading", () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept(), found] }, session: session() })

      const about = within(keptCard()).getByRole('button', { name: 'About Where it was made' })
      expect(within(keptCard()).getByRole('heading').parentElement.contains(about)).toBe(true)
      fireEvent.focus(about)

      const card = screen.getByRole('tooltip')
      expect(card.textContent).toContain('Made on this page')
      expect(card.textContent).toContain('cameracalibrator')
    })

    it('downloads the YAML files of every calibration kept, the one in use included', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })

      fireEvent.click(button('Download 2026-11-14 00:28'))
      expect(downloadYaml.mock.calls).toEqual([
        ['ovcs_mini_left.yaml', 'left kept'],
        ['ovcs_mini_right.yaml', 'right kept']
      ])

      downloadYaml.mockClear()
      fireEvent.click(button('Download Bench'))
      expect(downloadYaml.mock.calls).toEqual([
        ['ovcs_mini_left.yaml', 'left found'],
        ['ovcs_mini_right.yaml', 'right found']
      ])
      expect(within(row(/Shipped with the firmware/)).queryByRole('button', { name: /^(Download|Delete)/ })).toBeNull()
    })

    it("deletes the calibration in use once confirmed, saying the unit goes back to the firmware's calibration", async () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })

      fireEvent.click(button('Delete 2026-11-14 00:28'))

      expect(await answer('Delete')).toContain('goes back to the calibration shipped with the firmware')
      expect(actions.deleteSaved).toHaveBeenCalledWith('7')
    })

    it('keeps Delete off the calibration in use on a unit with no firmware calibration to go back to, saying why', () => {
      show({ inUse: { ...stored, canReset: false }, closed: true, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session() })

      const remove = button('Delete 2026-11-14 00:28')
      expect(remove.disabled).toBe(true)
      expect(remove.title).toBe('The unit has no calibration shipped with the firmware to go back to')
      expect(button('Delete Bench').disabled).toBe(false)
    })

    it('renames a calibration in place, and leaves it on Escape or an unchanged name', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [found] }, session: session() })

      fireEvent.click(button('Rename Bench'))
      const input = screen.getByLabelText('Name of Bench')
      fireEvent.change(input, { target: { value: ' Workshop ' } })
      fireEvent.click(button('Save'))
      expect(actions.renameSaved).toHaveBeenCalledWith('3', 'Workshop')
      expect(screen.queryByLabelText('Name of Bench')).toBeNull()

      fireEvent.click(button('Rename Bench'))
      fireEvent.keyDown(screen.getByLabelText('Name of Bench'), { key: 'Escape' })
      expect(screen.queryByLabelText('Name of Bench')).toBeNull()

      fireEvent.click(button('Rename Bench'))
      fireEvent.click(button('Save'))
      expect(actions.renameSaved).toHaveBeenCalledTimes(1)
    })

    it('puts the focus in the name when renaming, and back on Rename once left', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [found] }, session: session() })

      fireEvent.click(button('Rename Bench'))
      expect(document.activeElement).toBe(screen.getByLabelText('Name of Bench'))

      fireEvent.keyDown(screen.getByLabelText('Name of Bench'), { key: 'Escape' })
      expect(document.activeElement).toBe(button('Rename Bench'))

      fireEvent.click(button('Rename Bench'))
      fireEvent.click(button('Cancel'))
      expect(document.activeElement).toBe(button('Rename Bench'))
    })

    it('keeps the focus on the name while the rename it saved disables Rename', () => {
      show({ inUse: stored, closed: true, saved: { ovcs_mini: [found] }, session: session() })
      actions.renameSaved.mockImplementation(() => useCalibration.setState({ busy: true }))

      fireEvent.click(button('Rename Bench'))
      fireEvent.change(screen.getByLabelText('Name of Bench'), { target: { value: 'Workshop' } })
      fireEvent.click(button('Save'))

      expect(button('Rename Bench').disabled).toBe(true)
      expect(document.activeElement.textContent).toContain('Bench')
      expect(row(/Bench/).contains(document.activeElement)).toBe(true)
    })

    it("offers the firmware's calibration while another one is in use, and marks it when the unit runs on it", () => {
      const { unmount } = show({ inUse: stored, closed: true, saved: { ovcs_mini: [kept({ inForce: true })] }, session: session() })
      fireEvent.click(button('Use the calibration shipped with the firmware'))
      expect(actions.reset).toHaveBeenCalledTimes(1)
      unmount()

      show({ inUse: builtIn, closed: true, saved: { ovcs_mini: [found] }, session: session() })
      expect(within(row(/Shipped with the firmware/)).getByText('In use')).toBeTruthy()
      expect(query('Use the calibration shipped with the firmware')).toBeNull()
    })

    it('has no firmware row on a unit with no built-in calibration to go back to, and says so when nothing is kept', () => {
      const { unmount } = show({ inUse: { ...stored, canReset: false }, closed: true, saved: { ovcs_mini: [kept({ inForce: true })] }, session: session() })
      expect(within(keptCard()).queryByRole('listitem', { name: /Shipped with the firmware/ })).toBeNull()
      unmount()

      show({ inUse: none, closed: true, saved: {}, session: session() })
      expect(keptCard().textContent).toContain('None yet')
    })

    it('changes nothing while a calibration session runs', () => {
      show({ inUse: stored, saved: { ovcs_mini: [kept({ inForce: true }), found] }, session: session({ phase: 'applying', board, result }) })

      expect(button('Use Bench').disabled).toBe(true)
      expect(button('Delete Bench').disabled).toBe(true)
      expect(button('Rename Bench').disabled).toBe(true)
      expect(button('Use the calibration shipped with the firmware').disabled).toBe(true)
    })

    it('shows no baseline for a camera of its own', () => {
      show({ inUse: center, closed: true, saved: { center: [kept({ baselineM: null, stereoRmsPx: null, cameras: [{ name: 'center', rmsPx: 0.2 }] })] }, session: session() })

      expect(keptCard().textContent).not.toMatch(/baseline/i)
      expect(row(/2026-11-14 00:28/).textContent).toContain('0.20 px')
      expect(row(/2026-11-14 00:28/).textContent).not.toContain('center 0.20 px')
    })
  })

  describe('idle', () => {
    it('opens the steps in a dialog from the page\'s button, and closes it with Close or Escape', () => {
      show({ inUse: stored, closed: true, session: session() })
      expect(screen.queryByRole('dialog')).toBeNull()

      fireEvent.click(button('Calibrate again'))
      expect(within(screen.getByRole('dialog', { name: 'Calibrate' })).getByLabelText('Square size (mm)')).toBeTruthy()

      fireEvent.click(button('Close'))
      expect(screen.queryByRole('dialog')).toBeNull()

      fireEvent.click(button('Calibrate again'))
      fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' })
      expect(screen.queryByRole('dialog')).toBeNull()
    })

    it('keeps Tab inside the dialog, and closes it with Escape from any of its fields', () => {
      show({ inUse: stored, closed: true, session: session() })
      fireEvent.click(button('Calibrate again'))
      const dialog = screen.getByRole('dialog')
      expect(document.activeElement).toBe(dialog)

      const first = button('Close')
      const last = button('Start capturing')

      last.focus()
      fireEvent.keyDown(last, { key: 'Tab' })
      expect(document.activeElement).toBe(first)

      fireEvent.keyDown(first, { key: 'Tab', shiftKey: true })
      expect(document.activeElement).toBe(last)

      // Focus that left the dialog comes back into it.
      button('Download the calibration the unit uses').focus()
      fireEvent.keyDown(document.activeElement, { key: 'Tab' })
      expect(document.activeElement).toBe(first)

      screen.getByLabelText('Square size (mm)').focus()
      fireEvent.keyDown(document.activeElement, { key: 'Escape' })
      expect(screen.queryByRole('dialog')).toBeNull()
    })

    it('gives the focus back to the button that opened the dialog when it closes', () => {
      show({ inUse: stored, closed: true, session: session() })
      fireEvent.click(button('Calibrate again'))
      fireEvent.click(button('Close'))
      expect(document.activeElement).toBe(button('Calibrate again'))

      fireEvent.click(button('Calibrate again'))
      act(() => useCalibration.setState({ session: capturing() }))
      expect(screen.getByRole('dialog').contains(document.activeElement)).toBe(true)

      act(() => useCalibration.setState({ session: session() }))
      expect(screen.queryByRole('dialog')).toBeNull()
      expect(document.activeElement).toBe(button('Calibrate again'))
    })

    it('refuses a board of fewer than 3 inner corners a side, or out of bounds, and says the rule', () => {
      show({ inUse: stored, session: session() })

      for (const [label, value] of [
        ['Inner corners (columns)', '2'],
        ['Inner corners (columns)', '51'],
        ['Square size (mm)', '1001']
      ]) {
        fireEvent.change(screen.getByLabelText(label), { target: { value } })
        expect(button('Start capturing').disabled).toBe(true)
        expect(screen.getByText(/whole numbers from 3 to 50.*above 0, up to 1000 mm/)).toBeTruthy()
        fireEvent.change(screen.getByLabelText(label), { target: { value: label.startsWith('Square') ? '25' : '8' } })
        expect(button('Start capturing').disabled).toBe(false)
      }
    })

    it('keeps the dialog open while a session runs, without Close, and closes it when the session ends', () => {
      show({ inUse: stored, closed: true, session: capturing() })
      expect(screen.getByRole('dialog')).toBeTruthy()
      expect(query('Close')).toBeNull()
      expect(query('Calibrate again')).toBeNull()
      fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' })
      expect(screen.getByRole('dialog')).toBeTruthy()

      act(() => useCalibration.setState({ session: session() }))
      expect(screen.queryByRole('dialog')).toBeNull()
    })

    it('asks for the board in inner corners, prefilled with the default board, and starts with it', () => {
      show({ inUse: stored, session: session() })

      expect(screen.getByLabelText('Inner corners (columns)').value).toBe('8')
      expect(screen.getByLabelText('Inner corners (rows)').value).toBe('6')
      expect(screen.getByLabelText('Square size (mm)').value).toBe('25')

      fireEvent.click(button('Start capturing'))
      expect(actions.start).toHaveBeenCalledWith({ columns: 8, rows: 6, squareMm: 25 })
    })

    it('draws the board entered, its inner corners marked, and nothing for a board it cannot look for', () => {
      show({ inUse: stored, session: session() })

      const drawing = screen.getByRole('img', { name: 'Board of 9 × 7 squares, with 8 × 6 inner corners' })
      expect(drawing.querySelectorAll('circle')).toHaveLength(48)

      fireEvent.change(screen.getByLabelText('Inner corners (columns)'), { target: { value: '5' } })
      expect(screen.getByRole('img', { name: 'Board of 6 × 7 squares, with 5 × 6 inner corners' }).querySelectorAll('circle')).toHaveLength(30)

      fireEvent.change(screen.getByLabelText('Inner corners (columns)'), { target: { value: '' } })
      expect(screen.queryByRole('img', { name: /^Board of/ })).toBeNull()
    })

    it('starts with the board entered, and remembers it', () => {
      const { unmount } = show({ inUse: stored, session: session() })

      fireEvent.change(screen.getByLabelText('Inner corners (columns)'), { target: { value: '9' } })
      fireEvent.change(screen.getByLabelText('Square size (mm)'), { target: { value: '30.5' } })
      fireEvent.click(button('Start capturing'))
      expect(actions.start).toHaveBeenCalledWith({ columns: 9, rows: 6, squareMm: 30.5 })
      unmount()

      show({ inUse: stored, session: session() })
      expect(screen.getByLabelText('Inner corners (columns)').value).toBe('9')
    })

    const rule = 'Columns and rows must be different whole numbers from 3 to 50; the square size must be above 0, up to 1000 mm.'

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
      expect(button('Start capturing').disabled).toBe(true)
      expect(button('Start capturing').getAttribute('aria-describedby')).toBe(screen.getByText(rule).id)

      fireEvent.click(button('Start capturing'))
      expect(actions.start).not.toHaveBeenCalled()
    })
  })

  describe('capturing', () => {
    const coverage = () => screen.getByRole('group', { name: 'Board positions covered' })

    it('shows both previews, the four coverage bars and the sample count', () => {
      show({ inUse: stored, session: capturing() })

      const topics = dashboardSocket.channel.mock.calls.map(([topic]) => topic)
      expect(topics).toContain('preview:left')
      expect(topics).toContain('preview:right')

      const bars = within(coverage()).getAllByRole('progressbar')
      expect(bars.map((bar) => bar.getAttribute('aria-label'))).toEqual(['Left to right (X)', 'Top to bottom (Y)', 'Near to far (size)', 'Tilted (skew)'])
      expect(bars.map((bar) => bar.getAttribute('aria-valuenow'))).toEqual(['42', '80', '25', '100'])
      expect(coverage().textContent).toContain('42 %')
      expect(coverage().textContent).toContain('100 %')
      expect(screen.getByText('Views kept (samples)').parentElement.textContent).toContain('12')
    })

    it('calibrates only once the samples are good enough, and cancels', () => {
      show({ inUse: stored, session: capturing() })
      expect(button('Compute calibration').disabled).toBe(true)

      act(() => useCalibration.setState({ session: capturing({ goodEnough: true }) }))
      fireEvent.click(button('Compute calibration'))
      expect(actions.solve).toHaveBeenCalledTimes(1)

      fireEvent.click(button('Cancel'))
      expect(actions.cancel).toHaveBeenCalledTimes(1)
    })

    it('names the corners it looks for while neither camera sees the board', () => {
      show({ inUse: stored, session: capturing({ board: { columns: 9, rows: 7, squareMm: 25 } }) })
      expect(screen.getByText(/Looking for a board with 9 × 7 inner corners/)).toBeTruthy()

      act(() => useCalibration.setState({ session: capturing({ detection: detection({ left: null, right: null }) }) }))
      expect(screen.getByText(/Looking for a board with 8 × 6 inner corners/)).toBeTruthy()

      act(() =>
        useCalibration.setState({ session: capturing({ detection: detection({ left: [[0.1, 0.2]], right: null }) }) })
      )
      expect(screen.queryByText(/Looking for a board/)).toBeNull()
      expect(screen.getByRole('status').textContent).toBe('Board found.')
    })

    it('keeps the board found, and its corners drawn, through a detection that misses it', () => {
      vi.useFakeTimers()
      try {
        const corners = [[0.1, 0.2], [0.2, 0.2]]
        show({ inUse: stored, session: capturing({ detection: detection({ left: corners, right: corners }) }) })
        for (const stream of ['left', 'right']) {
          act(() => handlers[`preview:${stream}/frame`](new Uint8Array([1]).buffer))
          const image = screen.getByRole('img', { name: `${stream} preview` })
          Object.defineProperties(image, { naturalWidth: { value: 640 }, naturalHeight: { value: 480 } })
          fireEvent.load(image)
        }
        const drawn = () => document.querySelectorAll('svg[data-corners]').length

        act(() => useCalibration.setState({ session: capturing({ detection: detection({ left: null, right: null }) }) }))
        expect(screen.getByRole('status').textContent).toBe('Board found.')
        expect(drawn()).toBe(2)

        act(() => vi.advanceTimersByTime(500))
        expect(screen.getByRole('status').textContent).toMatch(/Looking for a board/)
        expect(drawn()).toBe(0)
      } finally {
        vi.useRealTimers()
      }
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
      act(() => useCalibration.setState({ session: capturing({ detection: detection({ left: corners, right: null }) }) }))
      const left = figure('left').querySelector('svg[data-corners]')
      expect(left.getAttribute('viewBox')).toBe('0 0 640 480')
      expect(left.querySelectorAll('circle')).toHaveLength(4)
      expect(left.querySelector('polyline').getAttribute('points')).toBe('64,96 128,96 64,144 128,144')
      const detected = left.getAttribute('class')
      expect(figure('right').querySelectorAll('svg[data-corners] circle')).toHaveLength(0)

      act(() => useCalibration.setState({ session: capturing({ detection: detection({ left: corners, right: corners }, true) }) }))
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

    expect(screen.getByText(/Computing the calibration from 40 views/)).toBeTruthy()
    fireEvent.click(button('Cancel'))
    expect(actions.cancel).toHaveBeenCalledTimes(1)
  })

  describe('solved', () => {
    const resultCard = () => screen.getByRole('region', { name: /^Calibrate( again)?$/ })
    const rms = (label) => within(resultCard()).getByRole('row', { name: new RegExp(`^${label}`) })

    it('judges no error it was not given', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, result: { ...result, cameras: [{ ...result.cameras[0], rmsPx: null }, result.cameras[1]] } }) })

      const left = screen.getByRole('row', { name: /Left camera error/ })
      expect(left.textContent).not.toMatch(/good|fair|poor/)
      expect(left.querySelector('.ovcs-status--ok')).toBeNull()
      expect(left.textContent).toContain('–')
    })

    it('reads the reprojection errors in colour and words: good under 0.5 px, fair to 2 px, poor over', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result }) })

      expect(rms('Left camera error').querySelector('.ovcs-status--ok').textContent).toContain('0.31 px, good')
      expect(rms('Right camera error').querySelector('.ovcs-status--warn').textContent).toContain('0.87 px, fair')
      expect(rms('Pair error').querySelector('.ovcs-status--error').textContent).toContain('2.40 px, poor')
    })

    it('reads 0.5 and 2 px as fair', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, result: { ...result, cameras: [{ ...result.cameras[0], rmsPx: 0.5 }, { ...result.cameras[1], rmsPx: 2 }] } }) })

      expect(rms('Left camera error').textContent).toContain('fair')
      expect(rms('Right camera error').textContent).toContain('fair')
    })

    it('compares with nothing on a unit without a calibration, under the title Calibrate', () => {
      show({ inUse: none, session: session({ phase: 'solved', board, result }) })

      expect(within(resultCard()).getByRole('heading').textContent).toBe('Calibrate')
      expect(within(resultCard()).queryByText('Used now')).toBeNull()
      expect(rms('Focal length').querySelectorAll('td')).toHaveLength(1)
    })

    it('names the step it is at among the three', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result }) })

      const steps = within(within(resultCard()).getByRole('list', { name: 'Steps' })).getAllByRole('listitem')
      expect(steps.map((step) => step.textContent)).toEqual(['✓Describe the board', '✓Show it to the cameras', '3Check the result'])
      expect(steps.map((step) => step.getAttribute('aria-current'))).toEqual([null, null, 'step'])
    })

    it('shows the baseline and the rectified focal length next to the ones in use', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result }) })

      expect(rms('Distance between cameras').textContent).toContain('59.8 mm')
      expect(rms('Distance between cameras').textContent).toContain('60.1 mm')
      expect(rms('Focal length').textContent).toContain('910.1')
      expect(rms('Focal length').textContent).toContain('905.7')
    })

    it('sets the focal length in use beside the new one only when both are for the same image size', () => {
      const half = { ...result, imageWidth: 640, imageHeight: 360, fxPx: 455.06 }
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result: half }) })

      expect(rms('Focal length').textContent).toContain('455.1')
      expect(rms('Focal length').textContent).not.toContain('905.7')
      expect(rms('Distance between cameras').textContent).toContain('60.1 mm')
    })

    it('applies, downloads both YAMLs and discards', () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, samples: 40, result }) })

      fireEvent.click(button('Use this calibration'))
      expect(actions.apply).toHaveBeenCalledTimes(1)

      fireEvent.click(button('Download the new calibration'))
      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_left.yaml', 'left solved')
      expect(downloadYaml).toHaveBeenCalledWith('ovcs_mini_right.yaml', 'right solved')

      fireEvent.click(button('Discard'))
      expect(actions.cancel).toHaveBeenCalledTimes(1)
    })

    it("shows the unit's refusal of an apply", () => {
      show({ inUse: stored, session: session({ phase: 'solved', board, result, error: 'the apply failed; the log says why' }) })

      expect(screen.getByRole('alert').textContent).toContain('the apply failed; the log says why')
      expect(button('Use this calibration')).toBeTruthy()
    })

    it('shows an apply in progress, with nothing to apply or discard', () => {
      show({ inUse: stored, session: session({ phase: 'applying', board, result }) })

      expect(within(resultCard()).getByText(/Applying/)).toBeTruthy()
      expect(query('Use this calibration')).toBeNull()
      expect(query('Discard')).toBeNull()
    })
  })

  it('says why a calibration file gives no calibration, and still offers to calibrate and to go back', () => {
    const unreadable = { ...none, canReset: true, error: 'cannot read /data/vision/calibration/stereo_left.yaml: permission denied' }
    show({ inUse: unreadable, closed: true, session: session() })

    expect(within(inUseCard()).getByRole('alert').textContent).toContain('permission denied')
    expect(button('Calibrate')).toBeTruthy()
    expect(button('Use the calibration shipped with the firmware')).toBeTruthy()
  })

  it('does not call a unit without a stereo pair uncalibrated', () => {
    useStatus.setState({ snapshot: { calibrated: null } })
    show({ inUse: center, session: session() })

    expect(screen.queryByText(/The unit is uncalibrated/)).toBeNull()
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

  it('says so on a unit with no camera to calibrate', () => {
    show({ unavailable: true })

    expect(screen.getByText(/no camera to calibrate/)).toBeTruthy()
    expect(query('Start capturing')).toBeNull()
  })

  describe('with a camera of its own beside the stereo pair', () => {
    const both = { calibrations: { ovcs_mini: stored, center }, selected: 'ovcs_mini' }
    it('works on the calibration the menu opened, under no title of its own', () => {
      useNavigation.setState({ page: 'calibration', calibrationId: 'center' })
      show({ ...both, session: session() })

      expect(useCalibration.getState().selected).toBe('center')
      expect(within(inUseCard()).getByRole('row', { name: /^Focal x/ }).textContent).toBe('Focal x (fx)880.5')
      expect(screen.queryByRole('heading', { level: 2 })).toBeNull()

      act(() => useNavigation.setState({ calibrationId: 'ovcs_mini' }))
      expect(within(inUseCard()).getByRole('columnheader', { name: 'Left' })).toBeTruthy()
    })

    it("shows a camera's one calibration, without a baseline, and downloads its YAML", () => {
      show({ ...both, selected: 'center', session: session() })

      expect(within(inUseCard()).queryAllByRole('columnheader')).toEqual([])
      expect(within(inUseCard()).getByRole('row', { name: /^Focal x/ }).textContent).toContain('880.5')
      expect(inUseCard().textContent).not.toMatch(/baseline/i)

      fireEvent.click(button('Download the calibration the unit uses'))
      expect(downloadYaml.mock.calls).toEqual([['center.yaml', 'center in use']])
    })

    it('shows the calibration a running session works on, whatever the menu opened', () => {
      useNavigation.setState({ page: 'calibration', calibrationId: 'ovcs_mini' })
      show({ ...both, session: capturing({ calibration: 'center' }) })

      expect(screen.getByText('center', { selector: 'figcaption span' })).toBeTruthy()
      expect(screen.queryByText('left', { selector: 'figcaption span' })).toBeNull()
    })

    it("reads a camera's solve: its one reprojection error and focal length, no baseline", () => {
      const solved = {
        cameras: [{ name: 'center', file: 'center.yaml', rmsPx: 0.2, yaml: 'center solved' }],
        stereoRmsPx: null,
        baselineM: null,
        fxPx: 870.25,
        samples: 30
      }
      show({ ...both, session: session({ phase: 'solved', board, calibration: 'center', result: solved }) })

      const figures = screen.getByRole('region', { name: /^Calibrate( again)?$/ })
      expect(within(figures).getByRole('row', { name: /Center camera error/ }).textContent).toContain('0.20 px, good')
      expect(within(figures).queryByRole('row', { name: /Pair error/ })).toBeNull()
      expect(within(figures).queryByRole('row', { name: /Distance between cameras/ })).toBeNull()
      expect(within(figures).getByRole('row', { name: /Focal length/ }).textContent).toContain('870.3 px')
      expect(within(figures).queryByText('Used now')).toBeNull()

      fireEvent.click(button('Download the new calibration'))
      expect(downloadYaml.mock.calls).toEqual([['center.yaml', 'center solved']])
    })
  })

  describe("a camera's position", () => {
    // The center camera 100 mm right of the left camera, 8 mm below it, turned 10° to the right.
    const cos = Math.cos((10 * Math.PI) / 180)
    const sin = Math.sin((10 * Math.PI) / 180)
    const rotation = [cos, 0, -sin, 0, 1, 0, sin, 0, cos]
    const translation = [-cos * 0.1, -0.008, -sin * 0.1]
    const pose = (attributes) => ({
      rotation,
      translation,
      distanceMm: 100.32,
      file: 'center_pose.yaml',
      yaml: 'pose in use',
      ...attributes
    })

    const measured = {
      id: 'center-pose',
      kind: 'pose',
      source: 'stored',
      storedAt: '2026-11-14T10:00:00Z',
      canReset: false,
      baselineM: null,
      rectifiedFx: null,
      error: null,
      cameras: [side('left', 912.34, 'left in use'), { ...side('center', 880.5, 'center in use'), file: 'center.yaml' }],
      pose: pose()
    }
    const unmeasured = { ...measured, source: 'none', storedAt: null, pose: null }
    const poseCard = () => screen.getByRole('region', { name: /Measured on this unit|shipped with the firmware|Not measured/ })
    const facts = () =>
      Object.fromEntries([...poseCard().querySelectorAll('dt')].map((label) => [label.textContent, lines(label.nextElementSibling)]))

    it('shows where the camera sits from the left camera, how far and how it is turned, then its rotation and translation', () => {
      show({ inUse: measured, closed: true, session: session() })

      expect(within(poseCard()).getByRole('heading').textContent).toBe('Measured on this unit')
      expect(poseCard().textContent).toContain(stamp(measured.storedAt))
      expect(facts()).toEqual({
        'Position from the left camera': ['100.0 mm right', '8.0 mm down', '0.0 mm forward'],
        'Distance to the left camera': ['100.3 mm'],
        'Turned (yaw, pitch, roll)': ['10.0° right', '0.0° up', '0.0° clockwise']
      })
      const matrix = within(poseCard()).getByRole('table', { name: /Rotation/ })
      expect(within(matrix).getAllByRole('row').map((row) => row.textContent)).toEqual([
        '0.98480.0000-0.1736',
        '0.00001.00000.0000',
        '0.17360.00000.9848'
      ])
      const translation = within(poseCard()).getByRole('table', { name: /Translation/ })
      expect(within(translation).getAllByRole('row').map((row) => row.textContent)).toEqual(['x-98.5', 'y-8.0', 'z-17.4'])
      expect(poseCard().querySelector('.font-mono')).toBeNull()
      expect(within(poseCard()).queryByText(/Focal length/)).toBeNull()

      fireEvent.click(button('Download the position the unit uses'))
      expect(downloadYaml.mock.calls).toEqual([['center_pose.yaml', 'pose in use']])
    })

    it('says a position not measured, with a dash for each figure, no rotation or translation and nothing to download', () => {
      show({ inUse: unmeasured, closed: true, session: session() })

      expect(within(poseCard()).getByRole('heading').textContent).toBe('Not measured')
      expect(poseCard().textContent).toContain('no distance')
      expect(Object.values(facts())).toEqual([['–'], ['–'], ['–']])
      expect(within(poseCard()).queryByRole('table')).toBeNull()
      expect(query('Download the position the unit uses')).toBeNull()
      expect(button('Calibrate')).toBeTruthy()
    })

    it('warns of a board that looks the same after a half turn, which can number the corners apart in two cameras', () => {
      show({ inUse: unmeasured, session: session() })
      expect(screen.getByText(/looks the same after a half turn/)).toBeTruthy()

      fireEvent.change(screen.getByLabelText('Inner corners (columns)'), { target: { value: '9' } })
      expect(screen.queryByText(/looks the same after a half turn/)).toBeNull()
    })

    it('shows both previews, the left camera first, with the corners found in each', () => {
      show({ inUse: measured, session: capturing({ calibration: 'center-pose' }) })

      const captions = [...document.querySelectorAll('figcaption span')].map((caption) => caption.textContent)
      expect(captions.slice(0, 2)).toEqual(['left', 'center'])
      expect(screen.getByText(/Hold the board still where both cameras see it whole/).textContent).toContain('or 40 views are kept')
    })

    it('reads a solved position: its error with its verdict, where the camera sits, beside the one in use, and downloads it', () => {
      const solved = {
        imageWidth: null,
        imageHeight: null,
        cameras: [],
        stereoRmsPx: null,
        baselineM: null,
        fxPx: null,
        samples: 24,
        pose: pose({ rmsPx: 0.62, yaml: 'pose solved', distanceMm: 100.32 })
      }
      show({ inUse: measured, session: session({ phase: 'solved', board, calibration: 'center-pose', result: solved }) })

      const figures = screen.getByRole('region', { name: /^Calibrate( again)?$/ })
      expect(within(figures).getByRole('row', { name: /Error \(reprojection RMS\)/ }).textContent).toContain('0.62 px, fair')
      expect(within(figures).getByRole('row', { name: /Position from the left camera/ }).textContent).toContain(
        '100.0 mm right, 8.0 mm down, 0.0 mm forward'
      )
      expect(within(figures).getByRole('row', { name: /Distance to the left camera/ }).textContent).toBe(
        'Distance to the left camera100.3 mm100.3 mm'
      )
      expect(within(figures).getByRole('row', { name: /Turned/ }).textContent).toContain('10.0° right')
      expect(within(figures).getByText('Used now')).toBeTruthy()
      expect(within(figures).queryByRole('row', { name: /Focal length/ })).toBeNull()

      fireEvent.click(button('Download the new calibration'))
      expect(downloadYaml.mock.calls).toEqual([['center_pose.yaml', 'pose solved']])
    })

    it('lists each position kept with its error and distance, and downloads its YAML', () => {
      const kept = {
        id: '9',
        name: 'Bench',
        origin: 'dashboard',
        createdAt: '2026-11-14T10:00:00Z',
        inForce: true,
        board: { columns: 9, rows: 6, squareMm: 30 },
        samples: 24,
        stereoRmsPx: null,
        baselineM: null,
        cameras: [],
        pose: pose({ rmsPx: 0.41, yaml: 'pose kept' })
      }
      show({ inUse: measured, closed: true, saved: { 'center-pose': [kept] }, session: session() })

      const card = screen.getByRole('region', { name: 'Calibrations kept on the unit' })
      const row = within(card).getByRole('listitem', { name: /Bench/ })
      expect([...row.querySelectorAll('dt')].map((label) => label.textContent)).toEqual(['Reprojection error', 'Distance to the left camera'])
      expect(row.textContent).toContain('0.41 px')
      expect(row.textContent).toContain('100.3 mm')
      expect(within(poseCard()).getByRole('heading').textContent).toBe('Measured on this unit')
      expect(poseCard().textContent).toContain(`Bench · made ${stamp(kept.createdAt)}`)
      expect(query('Download the position the unit uses')).toBeNull()

      fireEvent.click(within(row).getByRole('button', { name: 'Download Bench' }))
      expect(downloadYaml.mock.calls).toEqual([['center_pose.yaml', 'pose kept']])
    })

    it("says what the firmware's entry is for a position", () => {
      show({ inUse: { ...measured, canReset: true }, closed: true, session: session() })

      const card = screen.getByRole('region', { name: 'Calibrations kept on the unit' })
      expect(within(card).getByRole('listitem', { name: /Shipped with the firmware/ }).textContent).toContain('The position the firmware was built with')
    })
  })
})
