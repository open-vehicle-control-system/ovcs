import { useEffect, useState } from 'react'
import { OvcsBottomBarItem } from './OvcsBottomBar.jsx'
import OvcsStatus from './OvcsStatus.jsx'
import { useOvcsProduct } from './product.js'

const STATES = {
  connecting: ['muted', 'Connecting…'],
  connected: ['ok', 'Connected'],
  disconnected: ['error', 'Disconnected']
}

/** Whether the Phoenix `socket` is `connecting`, `connected` or `disconnected`. */
export function useOvcsConnection(socket) {
  const [state, setState] = useState(() => (socket.isConnected() ? 'connected' : 'connecting'))

  useEffect(() => {
    // The socket may have opened between the first render and this effect.
    if (socket.isConnected()) setState('connected')
    const refs = [
      socket.onOpen(() => setState('connected')),
      socket.onClose(() => setState('disconnected')),
      socket.onError(() => setState('disconnected'))
    ]
    return () => socket.off(refs)
  }, [socket])

  return state
}

/**
 * The dashboard's live connection, as an `OvcsBottomBarItem` labelled with the `OvcsShell`'s product: `state` as
 * `useOvcsConnection` answers it, and `hint`, an element after the label explaining it.
 */
export default function OvcsConnectionStatus({ state, hint, ...props }) {
  const product = useOvcsProduct()
  const [tone, label] = STATES[state]

  return (
    <OvcsBottomBarItem
      label={
        <>
          {product ?? 'Connection'}
          {hint}
        </>
      }
      {...props}
    >
      <OvcsStatus tone={tone} className="font-medium">
        {label}
      </OvcsStatus>
    </OvcsBottomBarItem>
  )
}
