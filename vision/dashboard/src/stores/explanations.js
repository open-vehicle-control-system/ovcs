import { create } from 'zustand'

/** Whether each step's How it works is open, by its group's id, for as long as the dashboard runs. */
export const useExplanations = create((set) => ({
  open: {},
  toggle: (groupId) => set((state) => ({ open: { ...state.open, [groupId]: !state.open[groupId] } }))
}))
