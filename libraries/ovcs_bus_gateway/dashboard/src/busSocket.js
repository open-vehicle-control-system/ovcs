import { onScopeDispose, ref, shallowRef } from 'vue'
import { Socket } from 'phoenix'

import { applyFrame } from './signals'

const REJOIN_MS = 1000

// `status` is 'connecting' until the gateway's first snapshot, 'live' after it, and
// 'disconnected' while the socket is down; the Phoenix client reconnects and rejoins.
export function useBusSocket() {
  const signals = shallowRef(new Map())
  const status = ref('connecting')
  const socket = new Socket('/socket')
  let channel = null
  let rejoinTimer = null
  let disposed = false

  function join() {
    channel = socket.channel('signals', {})

    channel.on('snapshot', (payload) => {
      signals.value = applyFrame(signals.value, { type: 'snapshot', signals: payload.signals })
      status.value = 'live'
    })
    channel.on('update', (payload) => {
      signals.value = applyFrame(signals.value, { type: 'update', signals: payload.signals })
    })
    channel.on('overloaded', () => {
      status.value = 'connecting'
    })
    // The gateway stops a channel that falls behind: a new join brings a fresh snapshot.
    channel.onClose(() => {
      if (!disposed) rejoinTimer = setTimeout(join, REJOIN_MS)
    })

    channel.join()
  }

  socket.onError(() => {
    status.value = 'disconnected'
  })
  socket.onClose(() => {
    status.value = 'disconnected'
  })

  socket.connect()
  join()

  onScopeDispose(() => {
    disposed = true
    clearTimeout(rejoinTimer)
    channel.leave()
    socket.disconnect()
  })

  return { signals, status }
}
