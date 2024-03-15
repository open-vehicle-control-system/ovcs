import { defineStore } from 'pinia'

const channelName = "vehicle"

export const useVehicle = defineStore('vehicle', {
    state: () => ({
        selected_gear: "parking",
        speed: 0,
        key_status: "off"
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