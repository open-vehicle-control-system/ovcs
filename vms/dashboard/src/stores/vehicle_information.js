import { defineStore } from 'pinia'

export const useVehicleInformation = defineStore('vehicleInformation', {
    state: () => ({
        selectedGear: "parking",
        speed: 0,
        keyStatus: "off"
    }),
})