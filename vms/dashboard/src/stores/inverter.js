import { defineStore } from 'pinia'

export const useInverter = defineStore('inverter', {
    state: () => ({
        rotationPerMinute: 0,
        outputVoltage: 0,
        effectiveTorque: 0,
        requestedTorque: 0,
        inverterCommunicationBoardTemperature: 0,
        insulatedGateBipolarTransistorTemperature: 0,
        insulatedGateBipolarTransistorBoardTemperature: 0,
        motorTemperature: 0
    }),
})