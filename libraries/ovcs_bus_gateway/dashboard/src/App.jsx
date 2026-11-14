import {
  OvcsBottomBar,
  OvcsBottomBarItem,
  OvcsConnectionStatus,
  OvcsMain,
  OvcsRegion,
  OvcsShell,
  OvcsShellBody,
  OvcsTopBar,
  useOvcsFirmware
} from '@ovcs/ui/react'
import { useDeferredValue, useEffect, useMemo, useRef, useState } from 'react'

import AdapterPage from './components/AdapterPage.jsx'
import BusMenu from './components/BusMenu.jsx'
import BusPage from './components/BusPage.jsx'
import FilterInput from './components/FilterInput.jsx'
import { fetchFirmware } from './firmware'
import { groupTree } from './signals'
import { useBusSocket } from './useBusSocket'
import { useSelection } from './useSelection'

const TICK_MS = 500

// The socket's status as the shared connection status names it; an overloaded channel waits for a fresh snapshot.
const CONNECTION = { live: 'connected', connecting: 'connecting', disconnected: 'disconnected' }

function useNow() {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), TICK_MS)
    return () => clearInterval(timer)
  }, [])
  return now
}

/** "/" focuses `input` from anywhere but a text field. */
function useSlashFocus(input) {
  useEffect(() => {
    function onKey(event) {
      if (event.key !== '/' || ['INPUT', 'TEXTAREA'].includes(event.target.tagName)) return
      event.preventDefault()
      input.current?.focus()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [input])
}

export default function App() {
  const { signals, status, nodes, adapters } = useBusSocket()
  const [filter, setFilter] = useState('')
  const deferredFilter = useDeferredValue(filter)
  const now = useNow()
  const [selection, select, openAdapter] = useSelection()
  const filterInput = useRef(null)
  useSlashFocus(filterInput)

  // The bus and the menu show every node; the tables only what the filter keeps.
  const bus = useMemo(() => groupTree(signals, '', nodes), [signals, nodes])
  const tree = useMemo(
    () => (deferredFilter ? groupTree(signals, deferredFilter, nodes) : bus),
    [signals, deferredFilter, nodes, bus]
  )
  const count = signals.size
  // Each fresh snapshot reads the firmware again, as after an upload.
  const firmware = useOvcsFirmware(fetchFirmware, status === 'live')

  return (
    <OvcsShell product="Bus Gateway">
      <OvcsRegion name="The top bar">
        <OvcsTopBar firmware={firmware}>
          <FilterInput ref={filterInput} filter={filter} onFilterChange={setFilter} />
        </OvcsTopBar>
      </OvcsRegion>

      <OvcsShellBody>
        <OvcsRegion name="The menu">
          <BusMenu
            bus={bus}
            count={count}
            adapters={adapters}
            selection={selection}
            onSelectNode={select}
            onOpenAdapter={openAdapter}
          />
        </OvcsRegion>
        <OvcsMain>
          <OvcsRegion name="This page" resetOn={selection.adapter ?? ''}>
            {selection.adapter ? (
              <AdapterPage id={selection.adapter} adapters={adapters} />
            ) : (
              <BusPage
                status={status}
                bus={bus}
                tree={tree}
                filter={deferredFilter}
                selection={selection}
                select={select}
                now={now}
              />
            )}
          </OvcsRegion>
        </OvcsMain>
      </OvcsShellBody>

      <OvcsRegion name="The status bar">
        <OvcsBottomBar>
          <OvcsConnectionStatus state={CONNECTION[status]} />
          {status === 'live' ? (
            <OvcsBottomBarItem label="Signals">
              <span className="font-medium tabular-nums text-ovcs-text">{count}</span>
            </OvcsBottomBarItem>
          ) : null}
        </OvcsBottomBar>
      </OvcsRegion>
    </OvcsShell>
  )
}
