import { useEffect, useId, useRef } from 'react'
import StatusCards from './components/StatusCards.jsx'
import Preview from './components/Preview.jsx'
import PipelineDiagram from './components/PipelineDiagram.jsx'
import ParameterPanel from './components/ParameterPanel.jsx'
import { OvcsCard, OvcsSaveBar } from '@ovcs/ui/react'
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

// Keeps focused controls clear of the sticky bar when the browser scrolls them into view.
function useScrollPaddingFor(ref) {
  useEffect(() => {
    const bar = ref.current
    if (!bar || typeof ResizeObserver === 'undefined') return undefined
    const root = document.documentElement
    const observer = new ResizeObserver(() => {
      root.style.scrollPaddingBottom = `${bar.offsetHeight}px`
    })
    observer.observe(bar)
    return () => {
      observer.disconnect()
      root.style.scrollPaddingBottom = ''
    }
  }, [ref])
}

function ParameterSaveBar() {
  const barRef = useRef(null)
  const unsaved = useParameters((state) => state.unsaved)
  const error = useParameters((state) => state.error)
  const save = useParameters((state) => state.save)
  const discard = useParameters((state) => state.discard)
  const reset = useParameters((state) => state.reset)
  const exportSnippet = useParameters((state) => state.exportSnippet)
  const dismissError = useParameters((state) => state.dismissError)

  useScrollPaddingFor(barRef)

  return (
    <OvcsSaveBar
      ref={barRef}
      unsaved={unsaved}
      error={error}
      onSave={save}
      onDiscard={discard}
      onResetAll={() => reset()}
      onExport={exportSnippet}
      onDismissError={dismissError}
      className="sticky bottom-0 z-10 -mx-4 -mb-3 border-t border-ovcs-border bg-ovcs-surface px-4 pb-3 pt-4"
    />
  )
}

export default function App() {
  const parametersHeadingId = useId()
  const snapshot = useStatus((state) => state.snapshot)
  const listen = useStatus((state) => state.listen)
  const startPolling = useParameters((state) => state.startPolling)
  const stopPolling = useParameters((state) => state.stopPolling)

  useEffect(() => listen(dashboardSocket), [listen])

  useEffect(() => {
    startPolling()
    return stopPolling
  }, [startPolling, stopPolling])

  const selectedGroupId = useSelectionInUrl()

  return (
    <main className="mx-auto max-w-7xl space-y-8 px-4 py-8 sm:px-6 lg:px-8">
      <h1 className="text-2xl font-semibold text-ovcs-text">Vision</h1>

      <section>
        <StatusCards status={snapshot} />
      </section>

      <div className="grid items-start gap-4 lg:grid-cols-2">
        <section aria-label="Previews" className="grid min-w-0 grid-cols-2 gap-4 lg:sticky lg:top-4 lg:self-start">
          <Preview stream="left" socket={dashboardSocket} />
          <Preview stream="right" socket={dashboardSocket} />
          <div className="col-span-2">
            <Preview stream="depth" socket={dashboardSocket} />
          </div>
        </section>

        <OvcsCard as="section" aria-labelledby={parametersHeadingId} className="flex min-w-0 flex-col gap-4">
          <h2 id={parametersHeadingId} className="text-lg font-semibold">
            Parameters
          </h2>
          <PipelineDiagram />
          <ParameterPanel groupId={selectedGroupId} />
          <ParameterSaveBar />
        </OvcsCard>
      </div>
    </main>
  )
}
