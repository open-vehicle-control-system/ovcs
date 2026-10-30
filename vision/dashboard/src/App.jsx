import { useEffect, useId } from 'react'
import StatusCards from './components/StatusCards.jsx'
import Preview from './components/Preview.jsx'
import PipelineDiagram from './components/PipelineDiagram.jsx'
import ParameterPanel from './components/ParameterPanel.jsx'
import SaveBar from './components/SaveBar.jsx'
import { dashboardSocket } from './services/socket.js'
import { useStatus } from './stores/status.js'
import { flowGroups, useParameters } from './stores/parameters.js'

const BOX_PARAM = 'box'

// Selects the box named in the URL once the groups are known, else the first of the flow.
function useSelectionInUrl() {
  const loaded = useParameters((state) => state.groups.length > 0)
  const selectedGroupId = useParameters((state) => state.selectedGroupId)

  useEffect(() => {
    if (!loaded || selectedGroupId != null) return
    const state = useParameters.getState()
    const wanted = new URLSearchParams(window.location.search).get(BOX_PARAM)
    const known = state.groups.some((group) => group.id === wanted)
    const id = known ? wanted : flowGroups(state)[0]?.id
    if (id != null) state.select(id)
  }, [loaded, selectedGroupId])

  useEffect(() => {
    if (selectedGroupId == null) return
    const url = new URL(window.location.href)
    url.searchParams.set(BOX_PARAM, selectedGroupId)
    window.history.replaceState(window.history.state, '', url)
  }, [selectedGroupId])

  return selectedGroupId
}

function useLeaveGuard(active) {
  useEffect(() => {
    if (!active) return undefined
    const ask = (event) => {
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', ask)
    return () => window.removeEventListener('beforeunload', ask)
  }, [active])
}

function ParameterSaveBar() {
  const unsaved = useParameters((state) => state.unsaved)
  const error = useParameters((state) => state.error)
  const save = useParameters((state) => state.save)
  const discard = useParameters((state) => state.discard)
  const reset = useParameters((state) => state.reset)
  const exportSnippet = useParameters((state) => state.exportSnippet)
  const dismissError = useParameters((state) => state.dismissError)

  return (
    <div className="border-t border-ovcs-border pt-4">
      <SaveBar
        unsaved={unsaved}
        error={error}
        onSave={save}
        onDiscard={discard}
        onResetAll={() => reset()}
        onExport={exportSnippet}
        onDismissError={dismissError}
      />
    </div>
  )
}

export default function App() {
  const parametersHeadingId = useId()
  const snapshot = useStatus((state) => state.snapshot)
  const listen = useStatus((state) => state.listen)
  const startPolling = useParameters((state) => state.startPolling)
  const stopPolling = useParameters((state) => state.stopPolling)
  const hasUnsaved = useParameters((state) => state.unsaved > 0)

  useEffect(() => listen(dashboardSocket), [listen])

  useEffect(() => {
    startPolling()
    return stopPolling
  }, [startPolling, stopPolling])

  const selectedGroupId = useSelectionInUrl()
  useLeaveGuard(hasUnsaved)

  return (
    <main className="mx-auto max-w-7xl space-y-8 px-4 py-8 sm:px-6 lg:px-8">
      <h1 className="text-2xl font-semibold text-ovcs-text">Vision</h1>

      <section>
        <StatusCards status={snapshot} />
      </section>

      <div className="grid items-start gap-4 lg:grid-cols-2">
        <section aria-label="Previews" className="grid min-w-0 grid-cols-2 gap-4">
          <Preview stream="left" socket={dashboardSocket} />
          <Preview stream="right" socket={dashboardSocket} />
          <div className="col-span-2">
            <Preview stream="depth" socket={dashboardSocket} />
          </div>
        </section>

        <section aria-labelledby={parametersHeadingId} className="ovcs-card flex min-w-0 flex-col gap-4">
          <h2 id={parametersHeadingId} className="text-lg font-semibold">
            Parameters
          </h2>
          <PipelineDiagram />
          <ParameterPanel groupId={selectedGroupId} />
          <ParameterSaveBar />
        </section>
      </div>
    </main>
  )
}
