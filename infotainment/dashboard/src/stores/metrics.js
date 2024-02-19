import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useMetricsStore = defineStore('metrics', {
  state: () => ({
    metrics: [],
  }),
  actions: {
  }
})
