import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useCarStatustore = defineStore('carStatus', {
  state: () => ({
    keyStatus: ""
  }),
  actions: {
  }
})
