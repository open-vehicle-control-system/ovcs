import { create } from 'zustand'

// The unit pushes a status a second: one this old is no longer what the unit does.
export const STALE_MS = 3000

/**
 * The unit's latest status, `snapshot`: `null` until the first, once the status channel fails, as when the socket
 * closes, and once none came for `STALE_MS`, so that nothing shown from it outlives the link.
 */
export const useStatus = create((set) => ({
  snapshot: null,
  // How many times the status channel joined: it joins again whenever the unit comes back, as after a reboot.
  joins: 0,
  listen(socket) {
    const channel = socket.channel('status', {})
    let staleTimer = null
    const forget = () => {
      clearTimeout(staleTimer)
      set({ snapshot: null })
    }
    channel.on('status', (snapshot) => {
      clearTimeout(staleTimer)
      staleTimer = setTimeout(forget, STALE_MS)
      set({ snapshot })
    })
    channel.onError(forget)
    channel.join().receive('ok', () => set((state) => ({ joins: state.joins + 1 })))
    return () => {
      clearTimeout(staleTimer)
      channel.leave()
    }
  }
}))
