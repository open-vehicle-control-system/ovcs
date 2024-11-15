import { defineStore } from 'pinia'

export const useVehicle = defineStore('vehicle', {
    state: () => ({
        networks: false,
        throttle: false,
        steering: false,
        braking: false,
        gear: false,
        energy: false
    }),
})