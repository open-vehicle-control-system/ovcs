import { create } from 'zustand'
import { fetchPages, fetchVehicle } from '../services/api.js'

/** The vehicle and its pages, as the VMS API describes them; `error` holds a failed load until the next one succeeds. */
export const useVehicle = create((set) => ({
  vehicle: null,
  pages: null,
  error: null,
  async load() {
    set({ error: null })
    try {
      const [vehicle, pages] = await Promise.all([fetchVehicle(), fetchPages()])
      set({ vehicle, pages })
    } catch (error) {
      set({ error: error.message })
    }
  }
}))
