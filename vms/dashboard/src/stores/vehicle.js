import { defineStore } from 'pinia'

export const useVehicle = defineStore('vehicle', {
    state: () => ({
        selectedGear: "parking",
        speed: 0,
        keyStatus: "off"
    }),
})