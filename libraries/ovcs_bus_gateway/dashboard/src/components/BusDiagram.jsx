import { focusClass } from '@ovcs/ui/react'

import { isFresh } from '../format'
import { nodeStatus, signalCount, staleCount } from '../signals'
import { STATUS_DOT } from './statusDot'

// The bus runs down the left edge on a narrow screen and along the bottom on a laptop; each link joins a node to it.
const BUS = 'absolute left-0 top-0 h-full w-1.5 rounded-full bg-ovcs-accent lg:top-auto lg:bottom-0 lg:h-1.5 lg:w-full'
const LINK = 'absolute -left-5 top-1/2 h-[3px] w-5 -translate-y-1/2 lg:left-1/2 lg:top-full lg:h-6 lg:w-[3px] lg:-translate-x-1/2 lg:translate-y-0'
const DROPPED =
  'bg-[repeating-linear-gradient(90deg,var(--ovcs-error)_0_4px,transparent_4px_8px)] lg:bg-[repeating-linear-gradient(180deg,var(--ovcs-error)_0_4px,transparent_4px_8px)]'

const publishing = (node, now) => node.sources.some((source) => source.signals.some((signal) => isFresh(signal, now)))

function linkClass(node, now) {
  if (node.connected === false) return DROPPED
  if (node.connected === null) return 'bg-ovcs-border'
  return publishing(node, now) ? 'bg-ovcs-accent animate-pulse motion-reduce:animate-none' : 'bg-ovcs-accent'
}

function summary(node) {
  if (node.sources.length === 0) return 'Presence only'
  return `${node.sources.length} components · ${signalCount(node)} signals`
}

function NodeBlock({ node, selected, onSelect, now }) {
  const status = nodeStatus(node)
  const stale = staleCount(node)
  const dropped = node.connected === false

  return (
    <>
      <span aria-hidden="true" data-link className={`${LINK} ${linkClass(node, now)}`} />
      <button
        type="button"
        aria-current={selected ? 'true' : undefined}
        aria-label={`${node.node}, ${status.label}, ${summary(node)}`}
        onClick={() => onSelect(node.node)}
        className={`flex h-full w-full min-w-0 flex-col gap-0.5 rounded-lg border bg-ovcs-surface px-3 py-2 text-left ${
          dropped ? 'border-ovcs-error' : 'border-ovcs-border'
        } ${selected ? 'shadow-[0_0_0_2px_var(--ovcs-accent)]' : 'hover:border-ovcs-accent'} ${focusClass}`}
      >
        <span className="flex min-w-0 items-center gap-2 font-semibold">
          <span aria-hidden="true" className={STATUS_DOT[status.tone]} />
          <span className="truncate" translate="no">
            {node.node}
          </span>
        </span>
        <span className="text-xs text-ovcs-muted">
          {dropped ? <span className="text-ovcs-error-text">Disconnected · </span> : null}
          {summary(node)}
          {stale > 0 ? <span className="text-ovcs-warn-text"> · {stale} stale</span> : null}
        </span>
      </button>
    </>
  )
}

/**
 * The bus with every node plugged into it: a node's link pulses while it publishes and turns red and dashed when the
 * node drops off. Selecting a node shows its signals.
 */
export default function BusDiagram({ bus, selected, onSelect, now }) {
  return (
    <div className="relative shrink-0 pl-5 lg:pb-6 lg:pl-0">
      <span aria-hidden="true" className={BUS} />
      <ul aria-label="Nodes on the bus" className="flex flex-col gap-2 lg:flex-row lg:gap-3">
        {bus.map((node) => (
          <li key={node.node} className="relative min-w-0 lg:flex-1">
            <NodeBlock node={node} selected={node.node === selected} onSelect={onSelect} now={now} />
          </li>
        ))}
      </ul>
    </div>
  )
}
