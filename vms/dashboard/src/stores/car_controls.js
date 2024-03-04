import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useCarControls = defineStore('carControls', {
    state: () => ({
        calibration_status: "disabled",
        raw_max_throttle: 0,
        low_raw_throttle_a: 0,
        high_raw_throttle_a: 0,
        low_raw_throttle_b: 0,
        high_raw_throttle_b: 0,
        raw_throttle_a: 0,
        raw_throttle_b: 0,
        requested_gear: "parking",
        throttle: 0
    }),
    getters: {
        calibrationEnabled: (state) =>
            state.calibration_status == "in_progress" || state.calibration_status == "started"
    },
    actions: {
    }
})