import { create } from 'zustand'
import { fetchExporters } from '../services/unit.js'

/** The unit's exporters as the API lists them; their live statuses come with the unit status (`exporterStatus`). */
export const useExporters = create((set) => ({
  exporters: [],
  async load() {
    try {
      set({ exporters: await fetchExporters() })
    } catch {
      // The exporters listed before stay until a load succeeds, at a later join of the status channel.
    }
  }
}))

/** The status of `exporter`: the latest the unit status reports for it, else the one it was listed with. */
export function exporterStatus(exporter, snapshot) {
  const live = snapshot?.exporters?.find((reported) => reported.id === exporter.id)
  return live?.status ?? exporter.status
}
