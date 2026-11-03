export const SUBSECTION_HEADING = 'px-3 text-xs font-medium text-ovcs-text'

// A warning item keeps its red border when selected.
export const STATUS_STYLES = {
  ok: { border: 'border-transparent', dot: null },
  warning: { border: 'border-ovcs-error', dot: 'ovcs-status ovcs-status--error' },
  off: { border: 'border-dashed border-ovcs-border text-ovcs-muted', dot: 'ovcs-status' }
}
