import { create } from 'zustand'

export const useStatus = create((set) => ({
  snapshot: null,
  listen(socket) {
    const channel = socket.channel('status', {})
    channel.on('status', (snapshot) => set({ snapshot }))
    channel.join()
    return () => channel.leave()
  }
}))
