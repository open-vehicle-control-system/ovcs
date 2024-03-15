import { defineStore } from 'pinia'

export const useVehicle = defineStore('vehicle', {
    state: () => ({
        selected_gear: "parking",
        speed: 0,
        key_status: "off"
    }),
})