import { useId, useState } from 'react'
import { focusClass as FOCUS } from '@ovcs/ui/react'
import Preview from '../Preview.jsx'
import CornerOverlay from './CornerOverlay.jsx'
import Coverage from './Coverage.jsx'
import Section from './Section.jsx'
import { SessionError } from './Errors.jsx'
import { selectedCalibration, useCalibration } from '../../stores/calibration.js'
import { loadBoard, saveBoard } from '../../services/calibration.js'
import { BUTTON, PRIMARY } from '../../styles.js'

const FIELDS = [
  { key: 'columns', label: 'Inner corners (columns)', step: 1, valid: (count) => Number.isInteger(count) && count >= 2 },
  { key: 'rows', label: 'Inner corners (rows)', step: 1, valid: (count) => Number.isInteger(count) && count >= 2 },
  { key: 'squareMm', label: 'Square size (mm)', step: 'any', valid: (millimetres) => millimetres > 0 }
]

const asFields = (board) => Object.fromEntries(FIELDS.map(({ key }) => [key, String(board[key])]))

const BOARD_RULE = 'Columns and rows must be different whole numbers of 2 or more; the square size must be above 0.'

// The board the fields describe, or null while the unit cannot detect it; equal counts make its orientation ambiguous.
function boardOf(fields) {
  const board = Object.fromEntries(FIELDS.map(({ key }) => [key, fields[key].trim() === '' ? NaN : Number(fields[key])]))
  return FIELDS.every(({ key, valid }) => valid(board[key])) && board.columns !== board.rows ? board : null
}

/** The board to look for, in inner corners, remembered in this browser; Start begins capturing. */
export function BoardForm() {
  const id = useId()
  const [fields, setFields] = useState(() => asFields(loadBoard()))
  const busy = useCalibration((state) => state.busy)
  const start = useCalibration((state) => state.start)
  const board = boardOf(fields)

  const submit = (event) => {
    event.preventDefault()
    if (!board) return
    saveBoard(board)
    start(board)
  }

  return (
    <Section title="New calibration">
      <form onSubmit={submit} className="flex flex-wrap items-end gap-3">
        {FIELDS.map(({ key, label, step }) => (
          <label key={key} htmlFor={`${id}-${key}`} className="flex flex-col gap-1 text-sm">
            <span className="text-ovcs-muted">{label}</span>
            <input
              id={`${id}-${key}`}
              type="number"
              inputMode={step === 1 ? 'numeric' : 'decimal'}
              min={step === 1 ? 2 : 0}
              step={step}
              required
              value={fields[key]}
              onChange={(event) => setFields((current) => ({ ...current, [key]: event.target.value }))}
              className={`min-h-9 w-36 rounded border border-ovcs-border bg-ovcs-bg px-2 tabular-nums ${FOCUS}`}
            />
          </label>
        ))}
        <button type="submit" disabled={busy || !board} aria-describedby={board ? undefined : `${id}-rule`} className={PRIMARY}>
          Start capturing
        </button>
      </form>
      {board ? null : (
        <p id={`${id}-rule`} className="text-sm text-ovcs-error-text">
          {BOARD_RULE}
        </p>
      )}
    </Section>
  )
}

// Shown while no camera finds the board: the usual cause is a board entered in squares.
function BoardHint() {
  const searching = useCalibration((state) => !state.session?.detection?.views?.some((view) => view.points))
  const columns = useCalibration((state) => state.session?.board?.columns)
  const rows = useCalibration((state) => state.session?.board?.rows)

  return searching ? (
    <p role="status" className="text-sm text-ovcs-muted">
      {`Looking for a board with ${columns} × ${rows} inner corners, which is ${columns + 1} × ${rows + 1} squares.`}
    </p>
  ) : null
}

// The names of the cameras being calibrated, as one string so that a push changing none does not render again.
const cameraNames = (state) => (selectedCalibration(state)?.cameras ?? []).map((camera) => camera.name).join(',')

/** Each camera with the board corners found, the samples' coverage, then Calibrate once it is good enough. */
export function Capturing({ socket }) {
  const cameras = useCalibration(cameraNames).split(',').filter(Boolean)
  const goodEnough = useCalibration((state) => state.session?.goodEnough === true)
  const busy = useCalibration((state) => state.busy)
  const solve = useCalibration((state) => state.solve)
  const cancel = useCalibration((state) => state.cancel)

  return (
    <Section title="New calibration">
      <BoardHint />
      <SessionError />
      <div className="flex min-w-0 flex-col gap-4 lg:flex-row">
        <div className={`grid min-w-0 flex-1 gap-3 ${cameras.length > 1 ? 'md:grid-cols-2' : ''}`}>
          {cameras.map((camera) => (
            <Preview key={camera} stream={camera} socket={socket} overlay={<CornerOverlay camera={camera} />} />
          ))}
        </div>
        <div className="flex shrink-0 flex-col gap-4 lg:w-56">
          <Coverage />
          <div className="flex flex-wrap gap-2">
            <button type="button" disabled={busy || !goodEnough} onClick={solve} className={PRIMARY}>
              Compute calibration
            </button>
            <button type="button" disabled={busy} onClick={cancel} className={BUTTON}>
              Cancel
            </button>
          </div>
        </div>
      </div>
    </Section>
  )
}

/** The unit computing the calibration from the samples; Cancel goes back to the board. */
export function Solving() {
  const samples = useCalibration((state) => state.session?.samples ?? 0)
  const busy = useCalibration((state) => state.busy)
  const cancel = useCalibration((state) => state.cancel)

  return (
    <Section title="New calibration">
      <p role="status" className="text-sm">
        {`Computing the calibration from ${samples} views…`}
      </p>
      <div>
        <button type="button" disabled={busy} onClick={cancel} className={BUTTON}>
          Cancel
        </button>
      </div>
    </Section>
  )
}
