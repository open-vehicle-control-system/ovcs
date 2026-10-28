import { defineStore } from 'pinia'

export const useStatus = defineStore('status', {
  state: () => ({
    snapshot: null
  }),
  actions: {
    listen(socket) {
      const channel = socket.channel('status', {})
      channel.on('status', (snapshot) => {
        this.snapshot = snapshot
      })
      channel.join()
    }
  }
})
