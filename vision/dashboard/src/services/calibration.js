import { request } from './parameters.js'
import { downloadFile } from './download.js'

export const DEFAULT_BOARD = { columns: 8, rows: 6, squareMm: 25 }
const BOARD_KEY = 'vision.calibration.board'

const act = async (type, attributes) => {
  const data = { type }
  if (attributes) data.attributes = attributes
  const document = await request(type, { method: 'POST', body: { data } })
  return document.data.attributes
}

export const startSession = (board) => act('calibration-sessions', { board })
export const cancelSession = () => act('calibration-cancels')
export const solveSession = () => act('calibration-solves')
export const applySession = () => act('calibration-applies')
export const resetCalibration = () => act('calibration-resets')

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
