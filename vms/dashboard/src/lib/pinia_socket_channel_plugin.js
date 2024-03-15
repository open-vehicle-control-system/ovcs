export const PiniaSocketChannelPlugin = context => {
    let init = function(socket, interval, channelName){
        let that = this
        let channel = socket.channel(channelName, {interval: interval})
        channel.on("updated", payload => {
            that.$patch(payload)
        })
        channel.join().receive("ok", () => {});
    };
    context.store.init = init;
  }