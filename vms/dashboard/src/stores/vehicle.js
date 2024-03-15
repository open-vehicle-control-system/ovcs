import { defineStore } from 'pinia'

export const useVehicle = defineStore('vehicle', {
    state: () => ({
        selected_gear: "parking",
        speed: 0,
        key_status: "off"
    }),
    actions: {
        init(socket, interval, channelName){
            let that = this
            let channel = socket.channel(channelName, {interval: interval})
            channel.on("updated", payload => {
                that.$patch(payload)
            })
            channel.join().receive("ok", () => {});
        },
    }
})