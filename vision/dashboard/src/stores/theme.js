import { create } from 'zustand'

// `index.html` reads the same key, to apply the choice before the first paint.
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

/** The dashboard's theme, `light` or `dark`: the one chosen on this browser, else the system's. */
export const useTheme = create((set, get) => ({
  theme: chosenTheme() ?? systemTheme(),
  toggle: () => {
    const theme = get().theme === 'dark' ? 'light' : 'dark'
    document.documentElement.dataset.theme = theme
    remember(theme)
    set({ theme })
  }
}))

// Until a theme is chosen, the page follows the system's, and so does the switch.
window.matchMedia?.(SYSTEM_DARK).addEventListener?.('change', (event) => {
  if (!document.documentElement.dataset.theme) useTheme.setState({ theme: event.matches ? 'dark' : 'light' })
})
