import { OvcsDot, focusClass } from '@ovcs/ui/react'

import { isLive } from '../format'

const SELECTED = 'border-ovcs-accent bg-[color-mix(in_srgb,var(--ovcs-accent)_12%,var(--ovcs-surface))] font-medium'

function Tab({ selected, live = false, count, children, ...props }) {
  return (
    <button
      type="button"
      aria-current={selected ? 'true' : undefined}
      className={`inline-flex min-h-8 items-center gap-1.5 rounded border px-2 text-xs ${
        selected ? SELECTED : 'border-ovcs-border bg-ovcs-surface hover:border-ovcs-accent'
      } ${focusClass}`}
      {...props}
    >
      <OvcsDot on={live} />
      <span translate="no">{children}</span>
      <span className="tabular-nums text-ovcs-muted">{count}</span>
    </button>
  )
}

/**
 * A node's components, one tab each after "All": a tab's dot is on while one of its values just changed. `names` gives
 * each source its short name.
 */
export default function ComponentTabs({ node, names, selected, onSelect, now }) {
  const total = node.sources.reduce((count, source) => count + source.signals.length, 0)

  return (
    <ul aria-label={`Components of ${node.node}`} className="flex shrink-0 flex-wrap gap-1.5">
      <li>
        <Tab selected={selected == null} count={total} onClick={() => onSelect(null)}>
          All
        </Tab>
      </li>
      {node.sources.map((source) => (
        <li key={source.source}>
          <Tab
            selected={selected === source.source}
            live={source.signals.some((signal) => isLive(signal, now))}
            count={source.signals.length}
            title={source.source}
            onClick={() => onSelect(source.source)}
          >
            {names.get(source.source) ?? source.source}
          </Tab>
        </li>
      ))}
    </ul>
  )
}
