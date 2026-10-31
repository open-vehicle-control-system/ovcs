import { create } from 'zustand'

/** The pages of the menu besides the pipeline's stages; `pipeline` is the selected stage's page. */
export const PAGES = ['overview', 'calibration', 'pipeline', 'ros2', 'api']

const PAGE_PARAM = 'page'
const BOX_PARAM = 'box'

/** The page the URL names: a `box` is the pipeline, an unknown or missing page the overview. */
export function pageFromUrl(search = window.location.search) {
  const params = new URLSearchParams(search)
  if (params.has(BOX_PARAM)) return 'pipeline'
  const page = params.get(PAGE_PARAM)
  return PAGES.includes(page) && page !== 'pipeline' ? page : 'overview'
}

/** Writes `page`, or for the pipeline the selected `box`, into the URL without a new history entry. */
export function writeUrl(page, box) {
  const url = new URL(window.location.href)
  url.searchParams.delete(PAGE_PARAM)
  url.searchParams.delete(BOX_PARAM)
  if (page === 'pipeline') {
    if (box != null) url.searchParams.set(BOX_PARAM, box)
  } else if (page !== 'overview') {
    url.searchParams.set(PAGE_PARAM, page)
  }
  window.history.replaceState(window.history.state, '', url)
}

export const useNavigation = create((set) => ({
  page: pageFromUrl(),
  go: (page) => set({ page })
}))
