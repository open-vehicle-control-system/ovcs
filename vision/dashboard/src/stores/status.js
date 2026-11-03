import { create } from 'zustand'

export const useStatus = create((set) => ({
  snapshot: null,
  // How many times the status channel joined: it joins again whenever the unit comes back, as after a reboot.
  joins: 0,
  listen(socket) {
    const channel = socket.channel('status', {})
    channel.on('status', (snapshot) => set({ snapshot }))
    channel.join().receive('ok', () => set((state) => ({ joins: state.joins + 1 })))
    return () => channel.leave()
  }
}))
