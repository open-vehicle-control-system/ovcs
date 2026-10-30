import { useEffect, useRef } from 'react'
import UnitStatus from './components/UnitStatus.jsx'
import Previews from './components/Previews.jsx'
import Menu from './components/Menu.jsx'
import OverviewPage from './pages/OverviewPage.jsx'
import CalibrationPage from './pages/CalibrationPage.jsx'
import Ros2Page from './pages/Ros2Page.jsx'
import ApiPage from './pages/ApiPage.jsx'
import ParameterPanel from './components/ParameterPanel.jsx'
import { OvcsCard, OvcsHeader, OvcsSaveBar, focusClass as FOCUS } from '@ovcs/ui/react'
import { dashboardSocket } from './services/socket.js'
import { useStatus } from './stores/status.js'
import { flowGroups, useParameters } from './stores/parameters.js'
import { useNavigation, writeUrl } from './stores/navigation.js'

const BOX_PARAM = 'box'

// On the pipeline, selects the box named in the URL once the groups are known, else the first of the flow; keeps the
// page and the box in the URL.
function useNavigationInUrl() {
  const page = useNavigation((state) => state.page)
  const loaded = useParameters((state) => state.groups.length > 0)
  const selectedGroupId = useParameters((state) => state.selectedGroupId)

  useEffect(() => {
    if (page !== 'pipeline' || !loaded || selectedGroupId != null) return
    const state = useParameters.getState()
    const wanted = new URLSearchParams(window.location.search).get(BOX_PARAM)
    const known = state.groups.some((group) => group.id === wanted)
    const id = known ? wanted : flowGroups(state)[0]?.id
    if (id != null) state.select(id)
  }, [page, loaded, selectedGroupId])

  // Until a box is selected, the URL keeps the one it names.
  useEffect(() => {
    if (page !== 'pipeline' || selectedGroupId != null) writeUrl(page, selectedGroupId)
  }, [page, selectedGroupId])

  return { page, selectedGroupId }
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

/** The parameters' error: a failed load until the next one succeeds, a failed action until dismissed. */
function ParameterError() {
  const error = useParameters((state) => state.error)
  const errorSource = useParameters((state) => state.errorSource)
  const dismissError = useParameters((state) => state.dismissError)

  if (!error) return null

  return (
    <div role="alert" className="flex min-w-0 items-center gap-2 rounded border border-ovcs-error px-2 py-1 text-sm">
      <p className="ovcs-status ovcs-status--error min-w-0 break-words">{error}</p>
      {errorSource === 'load' ? null : (
        <button
          type="button"
          aria-label="Dismiss error"
          onClick={dismissError}
          className={`min-h-7 shrink-0 rounded border border-ovcs-border px-2 text-xs hover:border-ovcs-accent ${FOCUS}`}
        >
          Dismiss
        </button>
      )}
    </div>
  )
}

function ParameterSaveBar() {
  const barRef = useRef(null)
  const unsaved = useParameters((state) => state.unsaved)
  const save = useParameters((state) => state.save)
  const discard = useParameters((state) => state.discard)
  const reset = useParameters((state) => state.reset)
  const exportSnippet = useParameters((state) => state.exportSnippet)

  useScrollPaddingFor(barRef)

  return (
    <OvcsSaveBar
      ref={barRef}
      unsaved={unsaved}
      onSave={save}
      onDiscard={discard}
      onResetAll={() => reset()}
      onExport={exportSnippet}
      className="sticky bottom-0 z-10 -mx-4 -mb-3 border-t border-ovcs-border bg-ovcs-surface px-4 pb-3 pt-4"
    />
  )
}

function PipelinePage({ groupId, snapshot }) {
  return (
    <div className="grid min-w-0 gap-4 lg:min-h-0 lg:grid-cols-[minmax(24rem,30rem)_minmax(0,1fr)] lg:grid-rows-1">
      <OvcsCard className="flex min-w-0 flex-col gap-4 lg:min-h-0">
        <div data-scroll="panel" className="lg:-mx-4 lg:min-h-0 lg:flex-1 lg:overflow-y-auto lg:px-4">
          <ParameterPanel groupId={groupId} />
        </div>
        <ParameterSaveBar />
      </OvcsCard>

      <div className="flex min-w-0 flex-col lg:min-h-0">
        <Previews status={snapshot} socket={dashboardSocket} />
      </div>
    </div>
  )
}

const PAGES = { overview: OverviewPage, calibration: CalibrationPage, ros2: Ros2Page, api: ApiPage }

export default function App() {
  const snapshot = useStatus((state) => state.snapshot)
  const listen = useStatus((state) => state.listen)
  const startPolling = useParameters((state) => state.startPolling)
  const stopPolling = useParameters((state) => state.stopPolling)

  useEffect(() => listen(dashboardSocket), [listen])

  useEffect(() => {
    startPolling()
    return stopPolling
  }, [startPolling, stopPolling])

  const { page, selectedGroupId } = useNavigationInUrl()
  const Page = PAGES[page]

  // On a laptop the page is the screen: only a page's own content scrolls.
  return (
    <div className="flex min-h-screen flex-col lg:h-screen lg:overflow-hidden">
      <OvcsHeader className="flex min-h-14 shrink-0 flex-wrap items-center gap-x-8 gap-y-2 px-4 py-2 lg:px-6">
        <h1 className="text-lg font-semibold text-ovcs-text">
          OVCS <span className="font-normal text-ovcs-muted">Vision</span>
        </h1>
        <ParameterError />
        <div className="ml-auto">
          <UnitStatus status={snapshot} />
        </div>
      </OvcsHeader>

      <div className="flex flex-1 flex-col lg:min-h-0 lg:flex-row">
        <Menu />
        <main className="flex min-w-0 flex-1 flex-col p-4 lg:min-h-0 lg:p-6">
          {page === 'pipeline' ? <PipelinePage groupId={selectedGroupId} snapshot={snapshot} /> : <Page />}
        </main>
      </div>
    </div>
  )
}
