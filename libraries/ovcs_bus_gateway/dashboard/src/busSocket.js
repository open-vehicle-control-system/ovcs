import { onScopeDispose, ref, shallowRef } from 'vue'
import { applyFrame } from './signals'

const RECONNECT_MS = 1000

export function useBusSocket() {
  const signals = shallowRef(new Map())
  const connected = ref(false)
  let socket = null
  let timer = null
  let disposed = false

  function connect() {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
    socket = new WebSocket(`${scheme}://${location.host}/ws`)

    socket.onopen = () => {
      connected.value = true
    }
    socket.onmessage = (event) => {
      signals.value = applyFrame(signals.value, JSON.parse(event.data))
    }
    socket.onclose = () => {
      connected.value = false
      if (!disposed) timer = setTimeout(connect, RECONNECT_MS)
    }
  }

  connect()

  onScopeDispose(() => {
    disposed = true
    clearTimeout(timer)
    socket.close()
  })

  return { signals, connected }
}
