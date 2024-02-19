import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const systemInformationStore = defineStore('systemInformation', {
  state: () => ({
    data: [],
  }),
  actions: {
  }
})
