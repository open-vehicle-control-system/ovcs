import { defineStore } from 'pinia'

const channelName = "inverter"

export const useInverter = defineStore('inverter', {
    state: () => ({
        rpm: 0,
        output_voltage: 0,
        effective_torque: 0,
        requested_torque: 0,
        inverter_communication_board_temperature: 0,
        insulated_gate_bipolar_transistor_temperature: 0,
        insulated_gate_bipolar_transistor_board_temperature: 0,
        motor_temperature: 0
    }),
    actions: {
        init(socket, interval){
            let that = this
            let channel = socket.channel(channelName, {interval: interval})
            channel.on("updated", payload => {
                that.$patch(payload)
            })
            channel.join().receive("ok", () => {});
        },
    }
})