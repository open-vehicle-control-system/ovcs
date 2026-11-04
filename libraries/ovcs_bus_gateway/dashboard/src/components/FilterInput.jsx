import { focusClass } from '@ovcs/ui/react'

/** The signal filter, in the top bar; `ref` is its input. */
export default function FilterInput({ ref, filter, onFilterChange }) {
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
