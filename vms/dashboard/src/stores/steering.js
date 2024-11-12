import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useSteering = defineStore('steering', {
    state: () => ({
        lwsAngle: 0,
        desiredAngle: 0,
        lwsAngularSpeed: 0,
        lwsTrimmingValid: false,
        lwsCalibrationValid: false,
        lwsSensorReady: false,
        lwsCalibrationStatus: "disabled",
    })
})