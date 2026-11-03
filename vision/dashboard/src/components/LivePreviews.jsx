import Previews from './Previews.jsx'
import { dashboardSocket } from '../services/socket.js'
import { useStatus } from '../stores/status.js'

/** The previews with the unit's latest status, which renders them alone. */
export default function LivePreviews() {
  const snapshot = useStatus((state) => state.snapshot)
  return <Previews status={snapshot} socket={dashboardSocket} />
}
