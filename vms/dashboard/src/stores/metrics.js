import { create } from 'zustand'

// The one `metrics` channel, whether it is joined, and how many watchers each subscribed metric has.
let channel = null
let joined = false
const watched = new Map()

const idOf = ({ module, key }) => `${module}/${key}`

// Pushes made while the channel is down are dropped: the rejoin subscribes what is watched then.
const push = (event, metric) => {
  if (channel && joined) channel.push(event, metric)
}

/**
 * The values of the metrics the shown page watches, by module then key, and the units their publishers gave them;
 * every push of the `metrics` channel replaces both.
 */
export const useMetrics = create((set) => ({
  data: {},
  units: {},
  listen(socket, interval) {
    const own = socket.channel('metrics', { interval })
    channel = own
    own.on('updated', (payload) => set({ data: payload.data ?? {}, units: payload.units ?? {} }))
    own.onError(() => (joined = false))
    own.onClose(() => (joined = false))
    // The server's channel starts with no subscriptions, after a reconnect too.
    own.join().receive('ok', () => {
      joined = true
      for (const { metric } of watched.values()) push('subscribe', metric)
    })
    return () => {
      own.leave()
      if (channel === own) {
        channel = null
        joined = false
      }
    }
  },
  watch(metrics) {
    for (const metric of metrics) {
      const entry = watched.get(idOf(metric))
      if (entry) {
        entry.count += 1
      } else {
        watched.set(idOf(metric), { metric, count: 1 })
        push('subscribe', metric)
      }
    }
    return () => {
      for (const metric of metrics) {
        const entry = watched.get(idOf(metric))
        entry.count -= 1
        if (entry.count === 0) {
          watched.delete(idOf(metric))
          push('unsubscribe', metric)
        }
      }
    }
  }
}))
