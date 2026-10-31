/** Visible focus ring for every interactive element. */
export const FOCUS = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ovcs-accent'

/** Joins the truthy class names. */
export const cx = (...names) => names.filter(Boolean).join(' ')
