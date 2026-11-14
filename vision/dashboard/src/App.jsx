import { useEffect, useRef, useState } from 'react'
import UnitStatus from './components/UnitStatus.jsx'
import Hint from './components/Hint.jsx'
import { HINTS } from './hints.js'
import LivePreviews from './components/LivePreviews.jsx'
import Menu from './components/Menu.jsx'
import CalibrationPage from './pages/CalibrationPage.jsx'
import ExporterPage from './pages/ExporterPage.jsx'
import ParameterPanel from './components/ParameterPanel.jsx'
import {
  OvcsBottomBar,
  OvcsCard,
  OvcsConnectionStatus,
  OvcsMain,
  OvcsSaveBar,
  OvcsShell,
  OvcsRegion,
  OvcsShellBody,
  OvcsTopBar,
  focusClass as FOCUS,
  useOvcsConnection,
  useOvcsBoard,
  useOvcsFirmware
} from '@ovcs/ui/react'
import { fetchBoard, fetchFirmware } from './services/unit.js'
import { dashboardSocket } from './services/socket.js'
import { BUTTON } from './styles.js'
import { useStatus } from './stores/status.js'
import { useExporters } from './stores/exporters.js'
import { useCalibration } from './stores/calibration.js'
import { orderedGroups, useParameters } from './stores/parameters.js'
import { boxFromUrl, useNavigation, writeUrl } from './stores/navigation.js'

// Keeps the page, its box, exporter or calibration, in the URL; on the pipeline, selects the URL's box once known, else the first box.
function useNavigationInUrl() {
  const page = useNavigation((state) => state.page)
  const exporterId = useNavigation((state) => state.exporterId)
  const calibrationId = useNavigation((state) => state.calibrationId)
  const loaded = useParameters((state) => state.groups.length > 0)
  const selectedGroupId = useParameters((state) => state.selectedGroupId)

  useEffect(() => {
    if (page !== 'pipeline' || !loaded || selectedGroupId != null) return
    const state = useParameters.getState()
    const wanted = boxFromUrl()
    const known = state.groups.some((group) => group.id === wanted)
    const id = known ? wanted : orderedGroups(state)[0]?.id
    if (id != null) state.select(id)
  }, [page, loaded, selectedGroupId])

  // Until a box is selected, the URL keeps the one it names.
  useEffect(() => {
    if (page !== 'pipeline' || selectedGroupId != null) writeUrl(page, selectedGroupId, exporterId, calibrationId)
  }, [page, selectedGroupId, exporterId, calibrationId])

  return { page, selectedGroupId, exporterId, calibrationId }
}

// The exporters and what the unit can calibrate are listed again whenever the unit comes back, as after a reboot
// with another configuration.
function useExportersListed() {
  const joins = useStatus((state) => state.joins)
  const load = useExporters((state) => state.load)
  const loadTargets = useCalibration((state) => state.loadTargets)

  useEffect(() => {
    if (joins > 0) {
      load()
      loadTargets()
    }
  }, [joins, load, loadTargets])
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

/**
 * The parameters' error: a failed action until dismissed, a failed load until the next one succeeds. A load fails
 * while the unit is unreachable, which the bottom bar already says, so a failed load shows only while connected.
 */
function ParameterError({ connection }) {
  const error = useParameters((state) => state.error)
  const errorSource = useParameters((state) => state.errorSource)
  const dismissError = useParameters((state) => state.dismissError)

  if (!error || (errorSource === 'load' && connection !== 'connected')) return null

  return (
    <div role="alert" className="flex min-w-0 items-center gap-2 rounded border border-ovcs-error px-2 py-1 text-sm">
      <p className="ovcs-status ovcs-status--error min-w-0 break-words text-ovcs-error-text">{error}</p>
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

  useScrollPaddingFor(barRef)

  return (
    <OvcsSaveBar
      ref={barRef}
      unsaved={unsaved}
      onSave={save}
      onDiscard={discard}
      onResetAll={() => reset()}
      className="sticky bottom-0 z-10 -mx-4 -mb-3 border-t border-ovcs-border bg-ovcs-surface px-4 pb-3 pt-4"
    />
  )
}

// The bottom bar's figures, which a status renders alone; the last snapshot is stale once disconnected.
function UnitStatusBar({ connection }) {
  const snapshot = useStatus((state) => state.snapshot)
  if (connection !== 'connected' || !snapshot) return null
  return <UnitStatus status={snapshot} />
}

/**
 * The videos and their figures: at the full width on the overview, beside the `panel` of a stage or a calibration,
 * in a card with its `footer`, filling the main's height from lg. Every such page renders them at the same place, so
 * going from one to another keeps the videos playing. `paused` leaves them out.
 */
function PreviewsPage({ panel, footer, paused }) {
  const layout = panel
    ? 'grid min-w-0 gap-4 lg:min-h-0 lg:flex-1 lg:grid-cols-[minmax(24rem,30rem)_minmax(0,1fr)] lg:grid-rows-1'
    : 'flex min-w-0 flex-col lg:min-h-0 lg:flex-1'

  return (
    <div className={layout}>
      {panel ? (
        <OvcsCard className="flex min-w-0 flex-col gap-4 lg:min-h-0">
          <div data-scroll="panel" className="lg:-mx-4 lg:min-h-0 lg:flex-1 lg:overflow-y-auto lg:px-4">
            {panel}
          </div>
          {footer}
        </OvcsCard>
      ) : null}

      <div className="flex min-w-0 flex-col lg:min-h-0 lg:flex-1">{paused ? null : <LivePreviews />}</div>
    </div>
  )
}

// A capture's previews join the channels of the same frames, which the socket holds once per topic.
const capturing = (state) => state.session?.phase === 'capturing'

export default function App() {
  const listen = useStatus((state) => state.listen)
  const startPolling = useParameters((state) => state.startPolling)
  const stopPolling = useParameters((state) => state.stopPolling)

  useEffect(() => listen(dashboardSocket), [listen])

  useEffect(() => {
    startPolling()
    return stopPolling
  }, [startPolling, stopPolling])

  useExportersListed()

  // Each join reads the firmware again, as after an upload.
  const joins = useStatus((state) => state.joins)
  const firmware = useOvcsFirmware(fetchFirmware, joins)
  const connection = useOvcsConnection(dashboardSocket)
  const board = useOvcsBoard(fetchBoard, connection === 'connected')
  const { page, selectedGroupId, exporterId, calibrationId } = useNavigationInUrl()
  const paused = useCalibration(capturing)
  const panel =
    page === 'pipeline' ? <ParameterPanel groupId={selectedGroupId} /> : page === 'calibration' ? <CalibrationPage /> : null

  return (
    <OvcsShell product="Vision">
      <OvcsRegion name="The top bar">
        <OvcsTopBar firmware={firmware} board={board}>
          <ParameterError connection={connection} />
        </OvcsTopBar>
      </OvcsRegion>

      <OvcsShellBody>
        <OvcsRegion name="The menu">
          <Menu />
        </OvcsRegion>
        <OvcsMain>
          <OvcsRegion name="This page" resetOn={`${page}/${exporterId}/${selectedGroupId}/${calibrationId}`}>
            {page === 'exporter' ? (
              <ExporterPage id={exporterId} />
            ) : (
              <PreviewsPage panel={panel} footer={page === 'pipeline' ? <ParameterSaveBar /> : null} paused={paused} />
            )}
          </OvcsRegion>
        </OvcsMain>
      </OvcsShellBody>

      <OvcsRegion name="The status bar">
        <OvcsBottomBar>
          <OvcsConnectionStatus state={connection} hint={<Hint hint={HINTS.connection} />} />
          <UnitStatusBar connection={connection} />
        </OvcsBottomBar>
      </OvcsRegion>
    </OvcsShell>
  )
}
