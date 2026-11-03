// Selection is a tint and a bar on the left edge, unlike the focus outline.
export const SELECTED = 'shadow-[inset_3px_0_0_var(--ovcs-accent)] bg-[color-mix(in_srgb,var(--ovcs-accent)_12%,var(--ovcs-surface))]'
export const SECTION_HEADING = 'px-3 text-xs font-semibold uppercase tracking-wide text-ovcs-muted'
export const SUBSECTION_HEADING = 'px-3 text-xs font-medium text-ovcs-text'

// A warning item keeps its red border when selected.
export const STATUS_STYLES = {
  ok: { border: 'border-transparent', dot: null },
  warning: { border: 'border-ovcs-error', dot: 'ovcs-status ovcs-status--error' },
  off: { border: 'border-dashed border-ovcs-border text-ovcs-muted', dot: 'ovcs-status' }
}
