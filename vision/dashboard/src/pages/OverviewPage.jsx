import Previews from '../components/Previews.jsx'
import { dashboardSocket } from '../services/socket.js'
import { useStatus } from '../stores/status.js'

/** The unit at a glance: its videos and their figures, at the full width. */
export default function OverviewPage() {
  const snapshot = useStatus((state) => state.snapshot)
  return (
    <div className="flex min-w-0 flex-col lg:min-h-0">
      <Previews status={snapshot} socket={dashboardSocket} />
    </div>
  )
}
