export const PiniaSocketChannelPlugin = context => {
    let channel = undefined
    let init = function(socket, interval, channelName, callback){
        let that = this
        channel = socket.channel(channelName, {interval: interval})
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

    let subscribeToMetric = function(metric){
        channel.push("subscribe", metric)
    }

    let unsubscribeToMetric = function(metric){
        channel.push("unsubscribe", metric)
    }
    context.store.init = init;
    context.store.subscribeToMetric = subscribeToMetric;
    context.store.unsubscribeToMetric = unsubscribeToMetric;
  }