import { useEffect, useState } from 'react'

/**
 * The firmware `fetchFirmware` answers, for the `OvcsTopBar`: read whenever `readWhen` turns truthy, as each time the
 * dashboard connects, so an upload shows its new version; `null` until first read. A failed read keeps what it had.
 */
export function useOvcsFirmware(fetchFirmware, readWhen) {
  const [firmware, setFirmware] = useState(null)

  useEffect(() => {
    if (!readWhen) return undefined
    let live = true
    fetchFirmware().then(
      (next) => {
        if (live) setFirmware(next)
      },
      () => {}
    )
    return () => {
      live = false
    }
  }, [fetchFirmware, readWhen])

  return firmware
}
