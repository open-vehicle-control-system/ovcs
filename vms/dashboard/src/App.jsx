import { useEffect } from 'react'
import {
  OvcsBottomBar,
  OvcsConnectionStatus,
  OvcsMain,
  OvcsShell,
  OvcsShellBody,
  OvcsTopBar,
  focusClass as FOCUS,
  useOvcsBoard,
  useOvcsFirmware
} from '@ovcs/ui/react'
import Menu from './components/Menu.jsx'
import DynamicPage from './pages/DynamicPage.jsx'
import NetworkPage from './pages/NetworkPage.jsx'
import { fetchBoard, fetchFirmware } from './services/api.js'
import { dashboardSocket } from './services/socket.js'
import { useConnection } from './stores/connection.js'
import { useMetrics } from './stores/metrics.js'
import { NETWORK, listenToHistory, pathOf, routeOf, useNavigation } from './stores/navigation.js'
import { useVehicle } from './stores/vehicle.js'

const NO_PAGES = []

// Once the pages are known, an unknown path, or the first page's own id, is replaced by the page's canonical path.
function useCanonicalPath(pages) {
  const path = useNavigation((state) => state.path)

  useEffect(() => {
    const route = routeOf(path, pages)
    if (route == null) return
    const canonical = pathOf(route, pages)
    if (canonical !== path) {
      window.history.replaceState(window.history.state, '', canonical)
      useNavigation.setState({ path: canonical })
    }
  }, [path, pages])
}

// The metrics channel's join carries the vehicle's refresh interval, so it waits for the vehicle.
function useMetricsChannel(refreshInterval) {
  const listen = useMetrics((state) => state.listen)

  useEffect(() => {
    if (refreshInterval == null) return undefined
    return listen(dashboardSocket, refreshInterval)
  }, [listen, refreshInterval])
}

function LoadError({ error }) {
  const load = useVehicle((state) => state.load)
  return (
    <div role="alert" className="flex flex-wrap items-center gap-3">
      <p className="ovcs-status ovcs-status--error text-sm text-ovcs-error-text">{error}</p>
      <button
        type="button"
        onClick={load}
        className={`min-h-7 rounded border border-ovcs-border px-2 text-xs hover:border-ovcs-accent ${FOCUS}`}
      >
        Retry
      </button>
    </div>
  )
}

function Content({ pages }) {
  const path = useNavigation((state) => state.path)
  const error = useVehicle((state) => state.error)

  if (error) return <LoadError error={error} />
  if (!pages) return <p className="text-sm text-ovcs-muted">Loading…</p>

  const route = routeOf(path, pages)
  if (route == null) return <p className="text-sm text-ovcs-muted">This vehicle declares no dashboard pages.</p>
  if (route === NETWORK) return <NetworkPage />

  const page = pages.find((candidate) => candidate.id === route)
  return <DynamicPage key={page.id} page={page} />
}

export default function App() {
  const vehicle = useVehicle((state) => state.vehicle)
  const pages = useVehicle((state) => state.pages)
  const load = useVehicle((state) => state.load)
  const watchConnection = useConnection((state) => state.watch)
  const connection = useConnection((state) => state.state)
  // Each connection reads the firmware again, as after an upload.
  const firmware = useOvcsFirmware(fetchFirmware, connection === 'connected')
  const board = useOvcsBoard(fetchBoard, connection === 'connected')

  useEffect(() => {
    load()
  }, [load])
  useEffect(() => listenToHistory(), [])
  useEffect(() => watchConnection(dashboardSocket), [watchConnection])
  useCanonicalPath(pages)
  useMetricsChannel(vehicle?.refreshInterval)

  return (
    <OvcsShell product="VMS">
      <OvcsTopBar firmware={firmware} board={board} />

      <OvcsShellBody>
        <Menu pages={pages ?? NO_PAGES} />
        <OvcsMain>
          <Content pages={pages} />
        </OvcsMain>
      </OvcsShellBody>

      <OvcsBottomBar>
        <OvcsConnectionStatus state={connection} />
      </OvcsBottomBar>
    </OvcsShell>
  )
}
