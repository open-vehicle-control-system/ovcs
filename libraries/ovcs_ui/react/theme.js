import { useSyncExternalStore } from 'react'

// An app's `index.html` reads the same key, to apply the choice before the first paint.
const STORAGE_KEY = 'ovcs-theme'
const SYSTEM_DARK = '(prefers-color-scheme: dark)'

// Storage can be missing or refused, as in a private window: the choice then lasts until the page reloads.
function chosenTheme() {
  try {
    const theme = window.localStorage.getItem(STORAGE_KEY)
    return theme === 'light' || theme === 'dark' ? theme : null
  } catch {
    return null
  }
}

function remember(theme) {
  try {
    window.localStorage.setItem(STORAGE_KEY, theme)
  } catch {
    // Kept for this page only.
  }
}

const systemTheme = () => (window.matchMedia?.(SYSTEM_DARK).matches ? 'dark' : 'light')

let theme = chosenTheme() ?? systemTheme()
const listeners = new Set()

function setTheme(next) {
  theme = next
  for (const listener of listeners) listener()
}

function subscribe(listener) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/** Switches the page between its light and dark themes; the choice stays on this browser. */
export function toggleTheme() {
  const next = theme === 'dark' ? 'light' : 'dark'
  document.documentElement.dataset.theme = next
  remember(next)
  setTheme(next)
}

/** The page's theme, `light` or `dark`: the one chosen on this browser, else the system's. */
export const useOvcsTheme = () => useSyncExternalStore(subscribe, () => theme)

// Until a theme is chosen, the page follows the system's, and so does the switch.
window.matchMedia?.(SYSTEM_DARK).addEventListener?.('change', (event) => {
  if (!document.documentElement.dataset.theme) setTheme(event.matches ? 'dark' : 'light')
})
