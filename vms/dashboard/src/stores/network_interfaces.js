import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useNetworkInterfaces = defineStore('networkInterfaces', {
    state: () => ({
        interfaces: []
    }),
    actions: {
    }
})