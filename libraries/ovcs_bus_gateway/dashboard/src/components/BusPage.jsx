import { OvcsBadge, OvcsDot } from '@ovcs/ui/react'

import { LIVE_MS } from '../format'
import { shortNames } from '../signals'
import BusDiagram from './BusDiagram.jsx'
import ComponentTabs from './ComponentTabs.jsx'
import SignalTree, { NodeTable, SourceTable, useCollapsed } from './SignalTree.jsx'

const LEGEND = (
  <p className="shrink-0 text-xs text-ovcs-muted">
    <OvcsDot on className="align-middle" /> value changed in the last {LIVE_MS / 1000} s ·{' '}
    <OvcsBadge tone="warn">stale</OvcsBadge> no longer received by the gateway · faint “Published” times are current
  </p>
)

function Note({ children }) {
  return <p className="text-ovcs-muted">{children}</p>
}

// On a laptop the tables scroll on their own, under the bus.
function Scroll({ children }) {
  return <div className="min-w-0 lg:min-h-0 lg:flex-1 lg:overflow-y-auto">{children}</div>
}

/** The selected node's components as tabs over its signals: all of them, or the selected component's. */
function NodeSignals({ busNode, node, source, onSelectSource, collapsed, onToggle, now }) {
  if (busNode.sources.length === 0) return <Note>{busNode.node} publishes no signals: it only reports its presence.</Note>
  if (!node) return <Note>No signals match.</Note>

  const names = shortNames(busNode.sources.map((entry) => entry.source))
  const shown = source ? node.sources.find((entry) => entry.source === source) : null

  return (
    <>
      <ComponentTabs node={node} names={names} selected={source} onSelect={onSelectSource} now={now} />
      <Scroll>
        {source == null ? (
          <NodeTable node={node} collapsed={collapsed} onToggle={onToggle} now={now} />
        ) : shown ? (
          <SourceTable source={shown} now={now} />
        ) : (
          <Note>No signals match.</Note>
        )}
      </Scroll>
    </>
  )
}

/**
 * The bus with its nodes, then the signals of the selection: every node's without one, else the selected node's.
 * `bus` holds every node, `tree` what the filter keeps.
 */
export default function BusPage({ status, bus, tree, filter, selection, select, now }) {
  const [collapsed, toggle] = useCollapsed()

  if (status === 'connecting') return <Note>Loading signals…</Note>
  if (bus.length === 0) return <Note>The gateway has no signals yet.</Note>

  const busNode = selection.node == null ? null : bus.find((node) => node.node === selection.node)
  const publishing = tree.some((node) => node.sources.length > 0)

  return (
    <div className="flex min-w-0 flex-col gap-4 lg:min-h-0 lg:flex-1">
      <BusDiagram bus={bus} selected={selection.node} onSelect={select} now={now} />
      {LEGEND}
      {selection.node == null ? (
        publishing ? (
          <Scroll>
            <SignalTree tree={tree} collapsed={collapsed} onToggle={toggle} now={now} />
          </Scroll>
        ) : (
          <Note>{filter ? 'No signals match.' : 'No node publishes signals yet.'}</Note>
        )
      ) : busNode ? (
        <NodeSignals
          busNode={busNode}
          node={tree.find((node) => node.node === selection.node)}
          source={selection.source}
          onSelectSource={(source) => select(selection.node, source)}
          collapsed={collapsed}
          onToggle={toggle}
          now={now}
        />
      ) : (
        <Note>{selection.node} is not on the bus.</Note>
      )}
    </div>
  )
}
