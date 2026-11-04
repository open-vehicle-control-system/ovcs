import { focusClass as FOCUS } from '@ovcs/ui/react'

/** The dashboard's buttons, as the save bar's. */
export const BUTTON = `min-h-9 rounded border border-ovcs-border px-3 text-sm enabled:hover:border-ovcs-accent disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`
export const PRIMARY = `${BUTTON} enabled:border-ovcs-accent font-semibold`
