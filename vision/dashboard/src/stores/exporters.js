import { create } from 'zustand'
import { fetchExporters } from '../services/unit.js'

const FIRST_RETRY_MS = 1000
const MAX_RETRY_MS = 30000

/**
 * The unit's exporters as the API lists them; their live statuses come with the unit status (`exporterStatus`). A
 * failed load keeps the exporters listed before and is tried again, the delay doubling up to a cap, until one succeeds.
 */
export const useExporters = create((set, get) => ({
  exporters: [],
  retryMs: FIRST_RETRY_MS,
  retryTimer: null,
  async load() {
    clearTimeout(get().retryTimer)
    try {
      set({ exporters: await fetchExporters(), retryMs: FIRST_RETRY_MS, retryTimer: null })
    } catch {
      const { retryMs } = get()
      set({ retryTimer: setTimeout(() => get().load(), retryMs), retryMs: Math.min(retryMs * 2, MAX_RETRY_MS) })
    }
  }
}))

/** The status of `exporter`: the latest the unit status reports for it, else the one it was listed with. */
export function exporterStatus(exporter, snapshot) {
  const live = snapshot?.exporters?.find((reported) => reported.id === exporter.id)
  return live?.status ?? exporter.status
}
