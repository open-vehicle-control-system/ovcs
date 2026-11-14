import { focusClass as FOCUS } from '@ovcs/ui/react'

const OUTLINED = `rounded border border-ovcs-border enabled:hover:border-ovcs-accent disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`

/** The dashboard's buttons, as the save bar's. */
export const BUTTON = `min-h-9 px-3 text-sm ${OUTLINED}`
export const PRIMARY = `${BUTTON} enabled:border-ovcs-accent font-semibold`
/** A button among several on an entry of a list. */
export const SMALL_BUTTON = `min-h-7 px-2 text-xs ${OUTLINED}`
