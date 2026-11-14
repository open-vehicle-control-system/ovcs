import { useEffect, useState } from 'react'

const FIRST_RETRY_MS = 1_000
const MAX_RETRY_MS = 30_000

/**
 * The firmware `fetchFirmware` answers, for the `OvcsTopBar`: read whenever `readWhen` turns truthy, as each time the
 * dashboard connects, so an upload shows its new version; `null` until first read. A failed read keeps what it had
 * and is tried again, the delay doubling up to a cap, until one succeeds or `readWhen` changes.
 */
export function useOvcsFirmware(fetchFirmware, readWhen) {
  const [firmware, setFirmware] = useState(null)

  useEffect(() => {
    if (!readWhen) return undefined
    let live = true
    let timer = null
    let retryMs = FIRST_RETRY_MS
    const read = async () => {
      try {
        const next = await fetchFirmware()
        if (live) setFirmware(next)
      } catch {
        if (!live) return
        timer = setTimeout(read, retryMs)
        retryMs = Math.min(retryMs * 2, MAX_RETRY_MS)
      }
    }
    read()
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [fetchFirmware, readWhen])

  return firmware
}
