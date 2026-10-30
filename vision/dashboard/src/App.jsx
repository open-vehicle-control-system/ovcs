import { useEffect } from 'react'
import StatusCards from './components/StatusCards.jsx'
import Preview from './components/Preview.jsx'
import { dashboardSocket } from './services/socket.js'
import { useStatus } from './stores/status.js'

const streams = ['left', 'right', 'depth']

export default function App() {
  const snapshot = useStatus((state) => state.snapshot)
  const listen = useStatus((state) => state.listen)

  useEffect(() => listen(dashboardSocket), [listen])

  return (
    <main className="mx-auto max-w-7xl space-y-8 px-4 py-8 sm:px-6 lg:px-8">
      <h1 className="text-2xl font-semibold text-ovcs-text">Vision</h1>

      <section>
        <StatusCards status={snapshot} />
      </section>

      <section className="grid gap-4 lg:grid-cols-3">
        {streams.map((stream) => (
          <Preview key={stream} stream={stream} socket={dashboardSocket} />
        ))}
      </section>
    </main>
  )
}
