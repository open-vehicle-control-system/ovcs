import { OvcsStatus } from '@ovcs/ui/react'
import { useConnection } from '../stores/connection.js'

const STATES = {
  connecting: ['muted', 'Connecting…'],
  connected: ['ok', 'Connected'],
  disconnected: ['error', 'Disconnected']
}

/** Whether the dashboard's live connection to the VMS is up. */
export default function ConnectionStatus() {
  const state = useConnection((store) => store.state)
  const [tone, label] = STATES[state]
  return (
    <OvcsStatus tone={tone} className="text-sm">
      {label}
    </OvcsStatus>
  )
}
