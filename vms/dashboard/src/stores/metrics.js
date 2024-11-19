import { defineStore } from 'pinia'

export const useMetrics = defineStore('metrics', {
    state: () => ({
        data: {}
    }),
})