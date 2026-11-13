import { create } from 'zustand'
import * as service from '../services/calibration.js'

const message = (error) => (error instanceof Error ? error.message : String(error))

/** The id of the calibration the page works on: the session's while one runs, else the one picked. */
export const selectedId = (state) => state.session?.calibration ?? state.selected

/** The calibration in use the page works on, `null` until the unit pushed it. */
export const selectedCalibration = (state) => state.calibrations[selectedId(state)] ?? null

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
    targets: [],
    async loadTargets() {
      try {
        set({ targets: await service.fetchCalibrations() })
      } catch {
        // The menu keeps what it listed before; the next join of the unit lists again.
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
      channel.on('calibration', (calibration) =>
        set((state) => ({
          calibrations: { ...state.calibrations, [calibration.id]: calibration },
          selected: state.selected ?? calibration.id
        }))
      )
      channel
        .join()
        .receive('ok', () => set({ unavailable: false }))
        .receive('error', (reply) => {
          // Other refusals, such as "unavailable", are rejoined by the channel itself.
          if (reply?.reason === 'nothing to calibrate') {
            set({ unavailable: true })
            channel.leave()
          }
        })
      return () => channel.leave()
    },

    select: (id) => set({ selected: id }),
    start: (board) => perform(() => service.startSession(selectedId(get()), board)),
    cancel: () => perform(service.cancelSession),
    solve: () => perform(service.solveSession),
    apply: () => perform(service.applySession),
    reset: () => perform(() => service.resetCalibration(selectedId(get()))),
    dismissError: () => set({ error: null })
  }
})
