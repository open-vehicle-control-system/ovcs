import { OvcsStatus, focusClass } from '@ovcs/ui/react'

/** The connection to the gateway, with how many signals it holds once live. */
export function ConnectionStatus({ status, count }) {
  if (status === 'live') {
    return (
      <OvcsStatus tone="ok" className="text-sm tabular-nums">
        Live · {count} signals
      </OvcsStatus>
    )
  }
  if (status === 'connecting') return <OvcsStatus className="text-sm">Connecting…</OvcsStatus>
  return (
    <OvcsStatus tone="error" className="text-sm">
      Disconnected, retrying
    </OvcsStatus>
  )
}

/** The signal filter; `ref` is its input. */
export function FilterInput({ ref, filter, onFilterChange }) {
  return (
    <input
      ref={ref}
      value={filter}
      onChange={(event) => onFilterChange(event.target.value)}
      type="search"
      name="filter"
      autoComplete="off"
      spellCheck={false}
      placeholder="Filter by node, source or name  ( / )"
      aria-label="Filter signals"
      className={`order-last w-full rounded border border-ovcs-border bg-ovcs-bg px-3 py-1.5 text-sm text-ovcs-text placeholder:text-ovcs-muted focus:border-ovcs-accent sm:order-none sm:w-72 ${focusClass}`}
    />
  )
}
