export const PiniaSocketChannelPlugin = context => {
    let init = function(socket, interval, channelName, callback){
        let that = this
        let channel = socket.channel(channelName, {interval: interval})
        channel.on("updated", payload => {
            if(callback){
                callback(that);
            };
            if (payload.data !== undefined) {
                that.$patch(payload)
            } else {
                that.$patch(payload.attributes)
            }
        })
        channel.join().receive("ok", () => {});
    };
    context.store.init = init;
  }