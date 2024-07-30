import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useCarControls = defineStore('carControls', {
    state: () => ({
        calibrationStatus: "disabled",
        rawMaxThrottle: 0,
        lowRawThrottleA: 0,
        highRawThrottleA: 0,
        lowRawThrottleB: 0,
        highRawThrottleB: 0,
        rawThrottleA: 0,
        rawThrottleB: 0,
        throttle: 0
    }),
    getters: {
        calibrationEnabled: (state) =>
            state.calibrationStatus == "in_progress" || state.calibrationStatus == "started"
    },
})