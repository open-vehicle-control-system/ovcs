import { createContext, useContext, useId, useRef, useState, useSyncExternalStore } from 'react'

// Whether the menu is hidden on a laptop, kept on this browser.
const STORAGE_KEY = 'ovcs-menu'
// Tailwind's `lg` breakpoint, from which the menu sits beside the page.
const LAPTOP = '(min-width: 1024px)'

export const OvcsMenuContext = createContext(null)

// Storage can be missing or refused, as in a private window: the choice then lasts until the page reloads.
function shownOnLaptop() {
  try {
    return window.localStorage.getItem(STORAGE_KEY) !== 'hidden'
  } catch {
    return true
  }
}

function remember(shown) {
  try {
    window.localStorage.setItem(STORAGE_KEY, shown ? 'shown' : 'hidden')
  } catch {
    // Kept for this page only.
  }
}

const laptopQuery = () => window.matchMedia?.(LAPTOP)

function subscribe(listener) {
  const query = laptopQuery()
  query?.addEventListener?.('change', listener)
  return () => query?.removeEventListener?.('change', listener)
}

// A browser that cannot say is taken for a laptop's.
const onLaptop = () => laptopQuery()?.matches ?? true

/**
 * The menu's state, which an `OvcsShell` holds for its `OvcsTopBar`'s Menu button and its `OvcsMenu`: on a laptop
 * the menu is shown until hidden, a choice the browser keeps; on a phone it is hidden until opened, and closes once
 * an entry is chosen.
 */
export function useMenuState() {
  const id = useId()
  const buttonRef = useRef(null)
  const laptop = useSyncExternalStore(subscribe, onLaptop)
  const [laptopShown, setLaptopShown] = useState(shownOnLaptop)
  const [phoneOpen, setPhoneOpen] = useState(false)
  const [present, setPresent] = useState(false)

  return {
    id,
    buttonRef,
    present,
    setPresent,
    laptopShown,
    phoneOpen,
    expanded: laptop ? laptopShown : phoneOpen,
    toggle() {
      if (!laptop) return setPhoneOpen(!phoneOpen)
      remember(!laptopShown)
      return setLaptopShown(!laptopShown)
    },
    closeOnPhone: () => setPhoneOpen(false)
  }
}

/** The menu's state from the `OvcsShell`, `null` outside one. */
export const useOvcsMenu = () => useContext(OvcsMenuContext)
