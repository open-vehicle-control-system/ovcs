import { create } from 'zustand'
import * as service from '../services/calibration.js'

const message = (error) => (error instanceof Error ? error.message : String(error))

export const useCalibration = create((set) => {
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
    session: null,
    inUse: null,
    error: null,
    busy: false,
    // A unit without a stereo unit refuses the join for good.
    unavailable: false,

    listen(socket) {
      const channel = socket.channel('calibration', {})
      channel.on('session', (session) => set({ session }))
      channel.on('in_use', (inUse) => set({ inUse }))
      channel
        .join()
        .receive('ok', () => set({ unavailable: false }))
        .receive('error', (reply) => {
          // Other refusals, such as "unavailable", are rejoined by the channel itself.
          if (reply?.reason === 'no stereo unit') {
            set({ unavailable: true })
            channel.leave()
          }
        })
      return () => channel.leave()
    },

    start: (board) => perform(() => service.startSession(board)),
    cancel: () => perform(service.cancelSession),
    solve: () => perform(service.solveSession),
    apply: () => perform(service.applySession),
    reset: () => perform(service.resetCalibration),
    dismissError: () => set({ error: null })
  }
})
