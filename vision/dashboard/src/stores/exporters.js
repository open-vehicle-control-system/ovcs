import { create } from 'zustand'
import { useShallow } from 'zustand/react/shallow'
import { fetchExporters } from '../services/unit.js'

const FIRST_RETRY_MS = 1000
const MAX_RETRY_MS = 30000

// Counts the loads started: of loads that overlap, only the last started is applied or tried again.
let loads = 0

/**
 * The unit's exporters in alphabetical order of their names; their live statuses come with the unit status
 * (`exporterStatus`). A failed load keeps the exporters listed before and is tried again, the delay doubling up to a
 * cap, until one succeeds.
 */
export const useExporters = create((set, get) => ({
  exporters: [],
  retryMs: FIRST_RETRY_MS,
  retryTimer: null,
  async load() {
    clearTimeout(get().retryTimer)
    loads += 1
    const started = loads
    try {
      const exporters = (await fetchExporters()).toSorted((a, b) => a.name.localeCompare(b.name))
      if (started === loads) set({ exporters, retryMs: FIRST_RETRY_MS, retryTimer: null })
    } catch {
      if (started !== loads) return
      const { retryMs } = get()
      set({ retryTimer: setTimeout(() => get().load(), retryMs), retryMs: Math.min(retryMs * 2, MAX_RETRY_MS) })
    }
  }
}))

const NO_OUTPUTS = []

const apiOutputs = (state) => state.exporters.find((exporter) => exporter.id === 'api')?.outputs ?? NO_OUTPUTS

/** The outputs the API exporter lists, none until it is listed. */
export const useApiOutputs = () => useExporters(apiOutputs)

// The API's outputs that the stereo unit's previews show.
const STEREO_OUTPUTS = { left: 'stereo_frame:left', right: 'stereo_frame:right', depth: 'stereo_pair' }

/**
 * The preview streams of the stereo unit's left and right cameras and of its depth, named under its prefix: the
 * `source` the API exporter lists for each of their outputs, `null` until it lists them.
 */
export function stereoStreams(outputs) {
  const source = (name) => outputs.find((output) => output.name === name)?.source ?? null
  return Object.fromEntries(Object.entries(STEREO_OUTPUTS).map(([key, name]) => [key, source(name)]))
}

/** `stereoStreams` of the outputs the API exporter lists. */
export const useStereoStreams = () => useExporters(useShallow((state) => stereoStreams(apiOutputs(state))))

/** The status of `exporter`: the latest the unit status reports for it, `null` until it reports one. */
export function exporterStatus(exporter, snapshot) {
  const live = snapshot?.exporters?.find((reported) => reported.id === exporter.id)
  return live?.status ?? null
}
