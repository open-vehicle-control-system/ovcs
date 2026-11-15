import { create } from 'zustand'
import {
  changeDisk,
  deleteRecording,
  ejectDisk,
  fetchDisks,
  fetchRecording,
  fetchRecordings,
  formatDisk,
  startRecording,
  stopRecording
} from '../services/recordings.js'

/**
 * The bag exporter's recordings and the disks they go on, as the API lists them. `refresh` reads the disks and the
 * recording in progress, `load` every recording, whose metadata the unit reads from the disks. An action is `busy`
 * until it answers; the lists are read again after it, and its failure is the `error` shown until the next action.
 */
export const useRecordings = create((set, get) => ({
  recordings: [],
  disks: [],
  loaded: false,
  loadError: null,
  busy: null,
  error: null,
  async load() {
    try {
      const [recordings, disks] = await Promise.all([fetchRecordings(), fetchDisks()])
      set({ recordings, disks, loaded: true, loadError: null })
    } catch (failure) {
      set({ loadError: failure.message })
    }
  },
  async refresh() {
    const live = recording(get())
    try {
      const [disks, current] = await Promise.all([fetchDisks(), live ? fetchRecording(live.id) : null])
      set({ disks, loadError: null })
      if (!current) return
      if (current.state !== 'recording') return get().load()
      set((state) => ({ recordings: state.recordings.map((listed) => (listed.id === current.id ? current : listed)) }))
    } catch (failure) {
      set({ loadError: failure.message })
    }
  },
  start: (choices) => run(set, get, 'start', () => startRecording(choices)),
  stop: (id) => run(set, get, `stop:${id}`, () => stopRecording(id)),
  remove: (id) => run(set, get, `delete:${id}`, () => deleteRecording(id)),
  moveDisk: (id, position) => run(set, get, `disk:${id}`, () => changeDisk(id, { position })),
  enableDisk: (id, enabled) => run(set, get, `disk:${id}`, () => changeDisk(id, { enabled })),
  ejectDisk: (id) => run(set, get, `eject:${id}`, () => ejectDisk(id)),
  formatDisk: (id, label) => run(set, get, `format:${id}`, () => formatDisk(id, label))
}))

async function run(set, get, busy, action) {
  set({ busy, error: null })
  try {
    await action()
  } catch (failure) {
    set({ error: failure.message })
  } finally {
    set({ busy: null })
    await get().load()
  }
}

/** The recording in progress, `null` while none records. */
export const recording = (state) => state.recordings.find((listed) => listed.state === 'recording') ?? null
