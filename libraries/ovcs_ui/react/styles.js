/** Visible focus ring for every interactive element. */
export const FOCUS = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ovcs-accent'

/** A selected menu item: a tint and a bar on its left edge, unlike the focus outline. */
export const MENU_SELECTED =
  'shadow-[inset_3px_0_0_var(--ovcs-accent)] bg-[color-mix(in_srgb,var(--ovcs-accent)_12%,var(--ovcs-surface))]'

/** A menu section's heading. */
export const MENU_HEADING = 'px-3 text-xs font-semibold uppercase tracking-wide text-ovcs-muted'

/** Joins the truthy class names. */
export const classNames = (...names) => names.filter(Boolean).join(' ')
