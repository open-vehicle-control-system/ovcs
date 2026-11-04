import { create } from 'zustand'

/** Whether the dashboard's socket is `connecting`, `connected` or `disconnected`. */
export const useConnection = create((set) => ({
  state: 'connecting',
  watch(socket) {
    // The socket connects on import, and may be open before this runs.
    if (socket.isConnected()) set({ state: 'connected' })
    const refs = [
      socket.onOpen(() => set({ state: 'connected' })),
      socket.onClose(() => set({ state: 'disconnected' })),
      socket.onError(() => set({ state: 'disconnected' }))
    ]
    return () => socket.off(refs)
  }
}))
