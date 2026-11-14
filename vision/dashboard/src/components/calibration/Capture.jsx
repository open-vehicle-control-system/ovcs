import { useId, useState } from 'react'
import { focusClass as FOCUS } from '@ovcs/ui/react'
import Preview from '../Preview.jsx'
import CornerOverlay from './CornerOverlay.jsx'
import Coverage from './Coverage.jsx'
import Flow from './Flow.jsx'
import { SessionError } from './Errors.jsx'
import { useHeld } from './held.js'
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

const INPUT = `min-h-9 w-16 rounded border border-ovcs-border bg-ovcs-bg px-2 text-center tabular-nums [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none ${FOCUS}`

// The largest board drawn square by square; a larger one is not drawn.
const DRAWN_SQUARES = 30

/** The board as entered: its squares, and a dot on each inner corner the unit looks for. */
function BoardDrawing({ board }) {
  if (!board || board.columns >= DRAWN_SQUARES || board.rows >= DRAWN_SQUARES) return null
  const across = board.columns + 1
  const down = board.rows + 1
  const squares = Array.from({ length: across * down }, (_, index) => [index % across, Math.floor(index / across)])
  const corners = Array.from({ length: board.columns * board.rows }, (_, index) => [
    (index % board.columns) + 1,
    Math.floor(index / board.columns) + 1
  ])

  return (
    <svg
      role="img"
      aria-label={`Board of ${across} × ${down} squares, with ${board.columns} × ${board.rows} inner corners`}
      viewBox={`0 0 ${across} ${down}`}
      className="h-28 w-auto shrink-0 rounded-sm bg-white"
    >
      {squares.map(([x, y]) => ((x + y) % 2 === 0 ? <rect key={`${x},${y}`} x={x} y={y} width="1" height="1" fill="black" /> : null))}
      <g className="text-ovcs-accent">
        {corners.map(([x, y]) => (
          <circle key={`${x},${y}`} cx={x} cy={y} r="0.2" fill="currentColor" />
        ))}
      </g>
    </svg>
  )
}

function Field({ id, field, value, onChange }) {
  return (
    <input
      id={id}
      aria-label={field.label}
      type="number"
      inputMode={field.step === 1 ? 'numeric' : 'decimal'}
      min={field.step === 1 ? 2 : 0}
      step={field.step}
      required
      autoComplete="off"
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className={INPUT}
    />
  )
}

/**
 * The board to look for, in inner corners, drawn as entered so that it can be checked against the printed one, and
 * remembered in this browser; Start begins capturing.
 */
export function BoardForm() {
  const id = useId()
  const [fields, setFields] = useState(() => asFields(loadBoard()))
  const busy = useCalibration((state) => state.busy)
  const start = useCalibration((state) => state.start)
  const board = boardOf(fields)
  const [columns, rows, squareMm] = FIELDS
  const field = (description) => (
    <Field
      id={`${id}-${description.key}`}
      field={description}
      value={fields[description.key]}
      onChange={(value) => setFields((current) => ({ ...current, [description.key]: value }))}
    />
  )

  const submit = (event) => {
    event.preventDefault()
    if (!board) return
    saveBoard(board)
    start(board)
  }

  return (
    <Flow step={0}>
      <p className="max-w-prose text-sm text-ovcs-muted">
        Fix a printed chessboard flat on a rigid plate. Count its inner corners, the dots on the drawing, where four squares
        meet, not its squares.
      </p>
      <form onSubmit={submit} className="flex flex-wrap items-center gap-x-8 gap-y-4">
        <BoardDrawing board={board} />
        <div className="flex flex-col gap-3 text-sm">
          <div className="flex flex-wrap items-end gap-x-6 gap-y-3">
            <div className="flex flex-col gap-1">
              <span className="text-ovcs-muted">Inner corners, across × down</span>
              <span className="flex items-center gap-2">
                {field(columns)}
                <span aria-hidden="true" className="text-ovcs-muted">
                  ×
                </span>
                {field(rows)}
                {board ? <span className="text-ovcs-muted">{`${board.columns + 1} × ${board.rows + 1} squares`}</span> : null}
              </span>
            </div>
            <div className="flex flex-col gap-1">
              <span className="text-ovcs-muted">Side of one square</span>
              <span className="flex items-center gap-2">
                {field(squareMm)}
                <span aria-hidden="true" className="text-ovcs-muted">
                  mm
                </span>
              </span>
            </div>
          </div>
          <div>
            <button type="submit" disabled={busy || !board} aria-describedby={board ? undefined : `${id}-rule`} className={PRIMARY}>
              Start capturing
            </button>
          </div>
        </div>
      </form>
      {board ? null : (
        <p id={`${id}-rule`} className="text-sm text-ovcs-error-text">
          {BOARD_RULE}
        </p>
      )}
    </Flow>
  )
}

// Whether a camera finds the board, on a line that stays in place; a board never found is usually one entered in squares.
function BoardHint() {
  const found = useHeld(useCalibration((state) => (state.session?.detection?.views?.some((view) => view.points) ? true : null)))
  const columns = useCalibration((state) => state.session?.board?.columns)
  const rows = useCalibration((state) => state.session?.board?.rows)

  return (
    <p role="status" className="text-sm text-ovcs-muted">
      {found ? 'Board found.' : `Looking for a board with ${columns} × ${rows} inner corners, which is ${columns + 1} × ${rows + 1} squares.`}
    </p>
  )
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
    <Flow step={1}>
      <p className="max-w-prose text-sm text-ovcs-muted">
        {cameras.length > 1
          ? 'Move the board slowly, whole in both images, until the four gauges are full.'
          : 'Move the board slowly, whole in the image, until the four gauges are full.'}{' '}
        A view is kept each time the board is found somewhere new.
      </p>
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
          <div className="flex flex-col gap-2">
            <button type="button" disabled={busy || !goodEnough} onClick={solve} className={`w-full ${PRIMARY}`}>
              Compute calibration
            </button>
            <button type="button" disabled={busy} onClick={cancel} className={`w-full ${BUTTON}`}>
              Cancel
            </button>
          </div>
        </div>
      </div>
    </Flow>
  )
}

/** The unit computing the calibration from the samples; Cancel goes back to the board. */
export function Solving() {
  const samples = useCalibration((state) => state.session?.samples ?? 0)
  const busy = useCalibration((state) => state.busy)
  const cancel = useCalibration((state) => state.cancel)

  return (
    <Flow step={2}>
      <p role="status" className="text-sm">
        {`Computing the calibration from ${samples} views…`}
      </p>
      <div>
        <button type="button" disabled={busy} onClick={cancel} className={BUTTON}>
          Cancel
        </button>
      </div>
    </Flow>
  )
}
