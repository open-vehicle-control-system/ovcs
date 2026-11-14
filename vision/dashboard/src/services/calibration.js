import { request } from './parameters.js'
import { downloadFile } from './download.js'

export const DEFAULT_BOARD = { columns: 8, rows: 6, squareMm: 25 }
const BOARD_KEY = 'vision.calibration.board'

// The unit answers a calibration put in force only once it has taken it, which restarts what reads it.
export const TAKE_TIMEOUT_MS = 60000

// `calibration` is the id of the calibration the action works on, for those that name one.
const act = async (type, { attributes, calibration, timeoutMs } = {}) => {
  const data = { type }
  if (attributes) data.attributes = attributes
  if (calibration) data.relationships = { calibration: { data: { type: 'calibrations', id: calibration } } }
  const document = await request(type, { method: 'POST', body: { data }, timeoutMs })
  return document.data.attributes
}

/** What the unit can calibrate: each calibration's `id` and `kind`, its stereo pair first. */
export async function fetchCalibrations() {
  const document = await request('calibrations')
  return document.data.map((resource) => ({ id: resource.id, kind: resource.attributes.kind }))
}

const capitalised = (name) => `${name.charAt(0).toUpperCase()}${name.slice(1)}`

/** The id of the calibration that measures the camera `name`'s position relative to the stereo pair. */
export const poseId = (name) => `${name}-pose`

/** The name a calibration goes by in the menu and on its page. */
export function calibrationName({ id, kind }) {
  if (kind === 'stereo') return 'Stereo cameras'
  if (kind === 'pose') return `${capitalised(id.slice(0, -poseId('').length))} camera position`
  return `${capitalised(id)} camera`
}

export const startSession = (calibration, board) => act('calibration-sessions', { attributes: { board }, calibration })
export const cancelSession = () => act('calibration-cancels')
export const solveSession = () => act('calibration-solves')
export const applySession = () => act('calibration-applies')
export const resetCalibration = (calibration) => act('calibration-resets', { calibration, timeoutMs: TAKE_TIMEOUT_MS })

const toSaved = (resource) => ({ id: resource.id, ...resource.attributes })

/** The calibrations the unit keeps for the calibration `id`, the newest first. */
export async function fetchSaved(calibration) {
  const document = await request(`saved-calibrations?filter[calibration]=${encodeURIComponent(calibration)}`)
  return document.data.map(toSaved)
}

/** Names the saved calibration `id`. */
export async function renameSaved(id, name) {
  const body = { data: { type: 'saved-calibrations', id, attributes: { name } } }
  return toSaved((await request(`saved-calibrations/${id}`, { method: 'PATCH', body })).data)
}

/** Removes the saved calibration `id`; the one in force once the unit has returned to the firmware's calibration. */
export const deleteSaved = (id) =>
  request(`saved-calibrations/${id}`, { method: 'DELETE', timeoutMs: TAKE_TIMEOUT_MS, answer: () => null })

/** Puts the saved calibration `id` back in force. */
export const selectSaved = (id) =>
  request('calibration-selections', {
    method: 'POST',
    timeoutMs: TAKE_TIMEOUT_MS,
    body: {
      data: {
        type: 'calibration-selections',
        relationships: { savedCalibration: { data: { type: 'saved-calibrations', id } } }
      }
    }
  })

export function loadBoard() {
  try {
    const board = JSON.parse(localStorage.getItem(BOARD_KEY))
    if (board && [board.columns, board.rows, board.squareMm].every((value) => Number.isFinite(value))) {
      return { columns: board.columns, rows: board.rows, squareMm: board.squareMm }
    }
  } catch {
    // Storage unavailable or corrupt: the default board applies.
  }
  return { ...DEFAULT_BOARD }
}

export function saveBoard(board) {
  try {
    localStorage.setItem(BOARD_KEY, JSON.stringify(board))
  } catch {
    // Storage unavailable: the board is not remembered.
  }
}

/** Saves `yaml` as the file `name`. */
export const downloadYaml = (name, yaml) => downloadFile(new Blob([yaml], { type: 'text/yaml' }), name)
