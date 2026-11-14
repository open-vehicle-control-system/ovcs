import { useEffect, useState } from 'react'

/** How long a board stays shown as found after a detection misses it, so that one missed frame does not blink. */
export const HOLD_MS = 400

/** `value`, or while it is `null` the last one it had, for `ms` after it went. */
export function useHeld(value, ms = HOLD_MS) {
  const [held, setHeld] = useState(value)

  useEffect(() => {
    if (value != null) {
      setHeld(value)
      return undefined
    }
    const timer = setTimeout(() => setHeld(null), ms)
    return () => clearTimeout(timer)
  }, [value, ms])

  return value ?? held
}
