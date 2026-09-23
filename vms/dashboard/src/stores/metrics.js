import { defineStore } from 'pinia'

export const useMetrics = defineStore('metrics', {
    state: () => ({
        data: {},
        // The unit each metric's publisher gave it, by module then key.
        units: {}
    }),
})