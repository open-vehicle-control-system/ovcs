import { create } from 'zustand'

/**
 * The pages of the menu: `pipeline` is the selected stage's page, `exporter` the selected exporter's, which the menu
 * lists from the unit.
 */
export const PAGES = ['overview', 'calibration', 'pipeline', 'exporter']

const PAGE_PARAMETER = 'page'
const BOX_PARAMETER = 'box'
const EXPORTER_PARAMETER = 'exporter'
const CALIBRATION_PARAMETER = 'calibration'

// The `page` values that open an exporter's page: the exporter's id.
const EXPORTER_PAGES = ['ros2', 'api']

/**
 * The page the URL names: a `box` is the pipeline, an `exporter`, or a `page` naming one, that exporter's page, an
 * unknown or missing page the overview.
 */
export function pageFromUrl(search = window.location.search) {
  const params = new URLSearchParams(search)
  if (params.has(BOX_PARAMETER)) return 'pipeline'
  if (exporterFromUrl(search) != null) return 'exporter'
  if (params.has(CALIBRATION_PARAMETER)) return 'calibration'
  const page = params.get(PAGE_PARAMETER)
  return PAGES.includes(page) && page !== 'pipeline' && page !== 'exporter' ? page : 'overview'
}

/** The box the URL names, if any. */
export const boxFromUrl = (search = window.location.search) => new URLSearchParams(search).get(BOX_PARAMETER)

/** The exporter the URL names, if any: its `exporter`, or a `page` naming one. */
export function exporterFromUrl(search = window.location.search) {
  const params = new URLSearchParams(search)
  const page = params.get(PAGE_PARAMETER)
  return params.get(EXPORTER_PARAMETER) ?? (EXPORTER_PAGES.includes(page) ? page : null)
}

/** The calibration the URL names, if any. */
export const calibrationFromUrl = (search = window.location.search) =>
  new URLSearchParams(search).get(CALIBRATION_PARAMETER)

/**
 * Writes `page` into the URL without a new history entry: for the pipeline its selected `box`, for an exporter's page
 * its `exporter`, for the calibration page its `calibration`.
 */
export function writeUrl(page, box, exporter, calibration) {
  const url = new URL(window.location.href)
  for (const parameter of [PAGE_PARAMETER, BOX_PARAMETER, EXPORTER_PARAMETER, CALIBRATION_PARAMETER]) {
    url.searchParams.delete(parameter)
  }
  if (page === 'pipeline') {
    if (box != null) url.searchParams.set(BOX_PARAMETER, box)
  } else if (page === 'exporter') {
    if (exporter != null) url.searchParams.set(EXPORTER_PARAMETER, exporter)
  } else if (page === 'calibration' && calibration != null) {
    url.searchParams.set(CALIBRATION_PARAMETER, calibration)
  } else if (page !== 'overview') {
    url.searchParams.set(PAGE_PARAMETER, page)
  }
  window.history.replaceState(window.history.state, '', url)
}

export const useNavigation = create((set) => ({
  page: pageFromUrl(),
  exporterId: exporterFromUrl(),
  calibrationId: calibrationFromUrl(),
  go: (page) => set({ page }),
  openExporter: (exporterId) => set({ page: 'exporter', exporterId }),
  openCalibration: (calibrationId) => set({ page: 'calibration', calibrationId })
}))
