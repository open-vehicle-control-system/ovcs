import { useEffect, useState } from 'react'
import { fetchFirmware } from '../services/unit.js'
import { useStatus } from '../stores/status.js'

// The commit, then the Nerves system, or the target where there is none, as on a host.
const summary = ({ revision, target, nervesSystem, nervesSystemVersion }) =>
  [revision, nervesSystem ? `${nervesSystem} ${nervesSystemVersion ?? ''}`.trim() : target].filter(Boolean).join(' · ')

/** The commit the firmware is built from and the Nerves system it runs on, read again whenever the unit comes back. */
export default function Firmware() {
  const joins = useStatus((state) => state.joins)
  const [firmware, setFirmware] = useState(null)

  useEffect(() => {
    if (joins === 0) return
    let live = true
    // A failed read leaves the line as it was until the next join.
    fetchFirmware().then(
      (next) => {
        if (live) setFirmware(next)
      },
      () => {}
    )
    return () => {
      live = false
    }
  }, [joins])

  const line = firmware ? summary(firmware) : ''
  if (!line) return null

  return (
    <p className="text-xs text-ovcs-muted">
      <span className="sr-only">Firmware </span>
      {line}
    </p>
  )
}
