import {
  OvcsMain,
  OvcsShell,
  OvcsShellBody,
  OvcsThemeSwitch,
  OvcsTopBar,
  OvcsTopBarEnd,
  OvcsTopBarTitle
} from '@ovcs/ui/react'
import { useDeferredValue, useEffect, useMemo, useRef, useState } from 'react'

import AdapterPage from './components/AdapterPage.jsx'
import BusMenu from './components/BusMenu.jsx'
import BusPage from './components/BusPage.jsx'
import { ConnectionStatus, FilterInput } from './components/TopBarControls.jsx'
import { groupTree } from './signals'
import { useBusSocket } from './useBusSocket'
import { useSelection } from './useSelection'

const TICK_MS = 500

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

  return (
    <OvcsShell>
      <OvcsTopBar>
        <OvcsTopBarTitle product="Bus Gateway" />
        <OvcsTopBarEnd className="flex-wrap">
          <ConnectionStatus status={status} count={count} />
          <FilterInput ref={filterInput} filter={filter} onFilterChange={setFilter} />
          <OvcsThemeSwitch />
        </OvcsTopBarEnd>
      </OvcsTopBar>

      <OvcsShellBody>
        <BusMenu
          bus={bus}
          count={count}
          adapters={adapters}
          selection={selection}
          onSelectNode={select}
          onOpenAdapter={openAdapter}
        />
        <OvcsMain>
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
        </OvcsMain>
      </OvcsShellBody>
    </OvcsShell>
  )
}
