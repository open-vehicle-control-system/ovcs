import { create } from 'zustand'
import * as service from '../services/calibration.js'

const message = (error) => (error instanceof Error ? error.message : String(error))

/**
 * The id of the calibration the page works on: the session's while one runs, else the one picked, or the first one
 * the unit pushed when it has none by that id.
 */
export const selectedId = (state) => {
  const id = state.session?.calibration ?? state.selected
  const [first] = Object.keys(state.calibrations)
  return id in state.calibrations || first === undefined ? id : first
}

/** The calibration in use the page works on, `null` until the unit pushed it. */
export const selectedCalibration = (state) => state.calibrations[selectedId(state)] ?? null

const FIRST_RETRY_MS = 1000
const MAX_RETRY_MS = 30000

// Count the reads started, of the targets and of each calibration's kept list: of reads that overlap, only the last started is applied.
let targetLoads = 0
const savedLoads = new Map()

export const useCalibration = create((set, get) => {
  // The session comes from the channel only: a response can arrive after a newer push.
  async function perform(action) {
    set({ busy: true, error: null })
    try {
      await action()
    } catch (error) {
      set({ error: message(error) })
    } finally {
      set({ busy: false })
    }
  }

  return {
    // What the unit can calibrate, for the menu: listed over HTTP, so that only the page joins the channel.
    // A failed read keeps what the menu listed and is tried again, the delay doubling up to a cap, until one succeeds.
    targets: [],
    targetsRetryMs: FIRST_RETRY_MS,
    targetsRetryTimer: null,
    async loadTargets() {
      clearTimeout(get().targetsRetryTimer)
      targetLoads += 1
      const started = targetLoads
      try {
        const targets = await service.fetchCalibrations()
        if (started === targetLoads) set({ targets, targetsRetryMs: FIRST_RETRY_MS, targetsRetryTimer: null })
      } catch {
        if (started !== targetLoads) return
        const { targetsRetryMs } = get()
        set({
          targetsRetryTimer: setTimeout(() => get().loadTargets(), targetsRetryMs),
          targetsRetryMs: Math.min(targetsRetryMs * 2, MAX_RETRY_MS)
        })
      }
    },

    session: null,
    // The calibrations in use, by id, in the order the unit pushed them: its stereo pair, then its cameras.
    calibrations: {},
    selected: null,
    error: null,
    busy: false,
    // A unit with nothing to calibrate refuses the join for good.
    unavailable: false,

    listen(socket) {
      const channel = socket.channel('calibration', {})
      channel.on('session', (session) => set({ session }))
      channel.on('saved', ({ calibration }) => get().loadSaved(calibration))
      channel.on('calibration', (calibration) => {
        set((state) => ({
          calibrations: { ...state.calibrations, [calibration.id]: calibration },
          selected: state.selected ?? calibration.id
        }))
        // The list of the calibration shown is read once that calibration is known, then at each change.
        if (get().saved[calibration.id] === undefined && selectedId(get()) === calibration.id) get().loadSaved(calibration.id)
      })
      // A session the channel no longer follows is not shown: its phase would open the dialog on a capture long over.
      channel.onError(() => set({ session: null }))
      channel
        .join()
        .receive('ok', () => {
          set({ unavailable: false })
          // A join after the first may follow changes made while the unit was out of reach.
          const shown = selectedId(get())
          if (shown != null) get().loadSaved(shown)
        })
        .receive('error', (reply) => {
          // Other refusals, such as "unavailable", are rejoined by the channel itself.
          if (reply?.reason === 'nothing to calibrate') {
            set({ unavailable: true })
            channel.leave()
          }
        })
      return () => {
        channel.leave()
        set({ session: null })
      }
    },

    // The calibrations the unit keeps, by calibration id, read over HTTP at each join and at each change the channel announces.
    saved: {},
    async loadSaved(id) {
      const started = (savedLoads.get(id) ?? 0) + 1
      savedLoads.set(id, started)
      try {
        const kept = await service.fetchSaved(id)
        if (savedLoads.get(id) === started) set((state) => ({ saved: { ...state.saved, [id]: kept } }))
      } catch {
        // The list keeps what it showed; the next change reads it again.
      }
    },

    select(id) {
      set({ selected: id })
      get().loadSaved(id)
    },
    useSaved: (id) => perform(() => service.selectSaved(id)),
    renameSaved: (id, name) => perform(() => service.renameSaved(id, name)),
    deleteSaved: (id) => perform(() => service.deleteSaved(id)),
    start: (board) => perform(() => service.startSession(selectedId(get()), board)),
    cancel: () => perform(service.cancelSession),
    solve: () => perform(service.solveSession),
    apply: () => perform(service.applySession),
    reset: () => perform(() => service.resetCalibration(selectedId(get()))),
    dismissError: () => set({ error: null })
  }
})
