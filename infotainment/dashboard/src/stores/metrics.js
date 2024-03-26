import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useMetricsStore = defineStore('metrics', {
  state: () => ({
    metrics: [],
  }),
  getters: {
    selectedGear: (state) => {
      let gear = state.metrics.find((metric) => {
        return metric.id == "selected_gear"
      })
      if(gear){
        return gear.attributes.value
      } else {
        return "parking"
      }
    }
  }
})
