import { Socket } from 'phoenix'
import { startTransition, useEffect, useState } from 'react'

import { applyFrame } from './signals'

const REJOIN_MS = 1000

// One empty list until the first status, so what is memoised on the nodes is not rebuilt on every render.
const NO_NODES = []

/**
 * The gateway's signals, from its `signals` channel, and its nodes and adapters, from its `status` channel. `status`
 * is 'connecting' until the gateway's first snapshot, 'live' after it, and 'disconnected' while the socket is down;
 * the Phoenix client reconnects and rejoins. `nodes` is empty and `adapters` `null` until the first status.
 */
export function useBusSocket() {
  const [signals, setSignals] = useState(() => new Map())
  const [status, setStatus] = useState('connecting')
  const [busStatus, setBusStatus] = useState(null)

  useEffect(() => {
    const socket = new Socket('/sockets/dashboard')
    const statusChannel = socket.channel('status', {})
    let channel = null
    let rejoinTimer = null
    let disposed = false

    function join() {
      channel = socket.channel('signals', {})

      channel.on('snapshot', (payload) => {
        setSignals((state) => applyFrame(state, { type: 'snapshot', signals: payload.signals }))
        setStatus('live')
      })
      // Updates stream in with every bus batch: rendering them must not hold up typing in the filter.
      channel.on('update', (payload) => {
        const receivedAt = Date.now()
        startTransition(() => {
          setSignals((state) => applyFrame(state, { type: 'update', signals: payload.signals }, receivedAt))
        })
      })
      channel.on('overloaded', () => setStatus('connecting'))
      // The gateway stops a channel that falls behind: a new join brings a fresh snapshot.
      channel.onClose(() => {
        if (!disposed) rejoinTimer = setTimeout(join, REJOIN_MS)
      })

      channel.join()
    }

    socket.onError(() => setStatus('disconnected'))
    socket.onClose(() => setStatus('disconnected'))

    socket.connect()
    statusChannel.on('status', setBusStatus)
    statusChannel.join()
    join()

    return () => {
      disposed = true
      clearTimeout(rejoinTimer)
      channel.leave()
      statusChannel.leave()
      socket.disconnect()
    }
  }, [])

  return { signals, status, nodes: busStatus?.nodes ?? NO_NODES, adapters: busStatus?.adapters ?? null }
}
