import { Socket } from 'phoenix'
import { startTransition, useEffect, useState } from 'react'

import { applyFrame } from './signals'

const REJOIN_MS = 1000

/**
 * The gateway's signals, kept current from its `signals` channel. `status` is 'connecting' until the gateway's
 * first snapshot, 'live' after it, and 'disconnected' while the socket is down; the Phoenix client reconnects and
 * rejoins.
 */
export function useBusSocket() {
  const [signals, setSignals] = useState(() => new Map())
  const [status, setStatus] = useState('connecting')

  useEffect(() => {
    const socket = new Socket('/sockets/dashboard')
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
    join()

    return () => {
      disposed = true
      clearTimeout(rejoinTimer)
      channel.leave()
      socket.disconnect()
    }
  }, [])

  return { signals, status }
}
