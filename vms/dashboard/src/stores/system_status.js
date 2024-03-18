import { defineStore } from 'pinia'

export const useSystemStatus = defineStore('systemStatus', {
    state: () => ({
        failedEmitters: []
    }),
})