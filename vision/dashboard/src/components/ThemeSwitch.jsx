import { focusClass as FOCUS } from '@ovcs/ui/react'
import { useTheme } from '../stores/theme.js'

const SUN = (
  <svg aria-hidden="true" viewBox="0 0 24 24" className="size-3.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
    <circle cx="12" cy="12" r="4.5" />
    <path d="M12 1.5v2M12 20.5v2M1.5 12h2M20.5 12h2M4.6 4.6 6 6M18 18l1.4 1.4M4.6 19.4 6 18M18 6l1.4-1.4" />
  </svg>
)

const MOON = (
  <svg aria-hidden="true" viewBox="0 0 24 24" className="size-3.5" fill="currentColor">
    <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z" />
  </svg>
)

/** Switches the dashboard between its light and dark themes; the choice stays on this browser. */
export default function ThemeSwitch() {
  const dark = useTheme((state) => state.theme === 'dark')
  const toggle = useTheme((state) => state.toggle)

  return (
    <button
      type="button"
      role="switch"
      aria-checked={dark}
      aria-label="Dark mode"
      title="Dark mode"
      onClick={toggle}
      className={`relative flex h-7 w-12 shrink-0 items-center rounded-full border border-ovcs-border bg-ovcs-bg hover:border-ovcs-accent ${FOCUS}`}
    >
      <span
        aria-hidden="true"
        className={`absolute left-0.5 flex size-5 items-center justify-center rounded-full bg-ovcs-surface text-ovcs-text shadow transition-transform motion-reduce:transition-none ${
          dark ? 'translate-x-5' : 'translate-x-0'
        }`}
      >
        {dark ? MOON : SUN}
      </span>
    </button>
  )
}
