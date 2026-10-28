import { onScopeDispose, ref, shallowRef } from 'vue'

import { applyFrame } from './signals'

const RECONNECT_MS = 1000

// `status` is 'connecting' until the gateway's first snapshot, 'live' after it, and
// 'disconnected' while the socket is down and retrying.
export function useBusSocket() {
  const signals = shallowRef(new Map())
  const status = ref('connecting')
  let socket = null
  let timer = null
  let disposed = false

  function connect() {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
    socket = new WebSocket(`${scheme}://${location.host}/ws`)

    socket.onmessage = (event) => {
      const frame = JSON.parse(event.data)
      signals.value = applyFrame(signals.value, frame)
      if (frame.type === 'snapshot') status.value = 'live'
    }
    socket.onclose = () => {
      status.value = 'disconnected'
      if (!disposed) timer = setTimeout(connect, RECONNECT_MS)
    }
  }

  connect()

  onScopeDispose(() => {
    disposed = true
    clearTimeout(timer)
    socket.close()
  })

  return { signals, status }
}
