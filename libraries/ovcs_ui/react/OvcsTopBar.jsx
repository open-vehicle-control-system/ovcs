import { useEffect, useState } from 'react'
import { boardClock, boardInterfaces } from './board.js'
import OvcsHeader from './OvcsHeader.jsx'
import OvcsStatus from './OvcsStatus.jsx'
import OvcsThemeSwitch from './OvcsThemeSwitch.jsx'
import { useOvcsProduct } from './product.js'
import { classNames } from './styles.js'

/**
 * What a firmware answers about itself, as `[label, value]` pairs: its commit as the version, its Nerves system or,
 * where there is none, as on a host, its target, and its vehicle. A missing part is left out.
 */
export function firmwareFacts(firmware) {
  if (!firmware) return []
  const { revision, target, nervesSystem, nervesSystemVersion, vehicle } = firmware
  const system = nervesSystem ? `${nervesSystem} ${nervesSystemVersion ?? ''}`.trim() : target
  return [
    ['Version', revision],
    ['System', system],
    ['Vehicle', vehicle]
  ].filter(([, value]) => value)
}

/** The firmware's facts, each value after its label. */
function FirmwareFacts({ firmware }) {
  const facts = firmwareFacts(firmware)
  if (facts.length === 0) return null

  return (
    <dl aria-label="Firmware" className="flex flex-wrap items-baseline gap-x-5 gap-y-1 text-xs">
      {facts.map(([label, value]) => (
        <div key={label} className="flex items-baseline gap-1.5">
          <dt className="text-ovcs-muted">{label}</dt>
          <dd className={classNames('font-medium text-ovcs-text', label === 'Version' && 'font-mono')}>{value}</dd>
        </div>
      ))}
    </dl>
  )
}

/** This browser's time, renewed every second. */
function useNow() {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1_000)
    return () => clearInterval(timer)
  }, [])
  return now
}

/** The board's interfaces, each name before its addresses, then its clock, ticking, with its synchronization. */
function BoardFacts({ board }) {
  const now = useNow()
  if (!board) return null
  const clock = boardClock(board, now)

  return (
    <dl aria-label="Board" className="flex flex-wrap items-baseline gap-x-5 gap-y-1 text-xs">
      {boardInterfaces(board).map(([name, addresses]) => (
        <div key={name} className="flex items-baseline gap-1.5">
          <dt className="text-ovcs-muted">{name}</dt>
          <dd className="font-mono font-medium text-ovcs-text">{addresses}</dd>
        </div>
      ))}
      <div className="flex items-baseline gap-1.5">
        <dt className="text-ovcs-muted">Clock</dt>
        <dd className="font-mono font-medium text-ovcs-text">{clock.time}</dd>
        {clock.state && (
          <dd>
            <OvcsStatus tone={clock.tone}>{clock.state}</OvcsStatus>
          </dd>
        )}
      </div>
    </dl>
  )
}

/** "OVCS" and the product, then the vehicle once known: the browser tab's title. */
function usePageTitle(product, vehicle) {
  useEffect(() => {
    document.title = [`OVCS ${product}`, vehicle].filter(Boolean).join(' · ')
  }, [product, vehicle])
}

/**
 * The page's sticky top bar, the same on every dashboard: "OVCS" and the `OvcsShell`'s product, then `children`, then
 * at its end the `board`'s interfaces and clock, as `useOvcsBoard` reads them, the `firmware`'s version, system and
 * vehicle (`revision`, `target`, `nervesSystem`, `nervesSystemVersion`, `vehicle`) and the `OvcsThemeSwitch`, last;
 * its content wraps on a narrow screen. It titles the browser tab with "OVCS", the product and the vehicle.
 */
export default function OvcsTopBar({ firmware, board, className, children, ...props }) {
  const product = useOvcsProduct()
  usePageTitle(product, firmware?.vehicle)

  return (
    <OvcsHeader
      className={classNames('flex min-h-14 shrink-0 flex-wrap items-center gap-x-8 gap-y-2 px-4 py-2 lg:px-6', className)}
      {...props}
    >
      <h1 className="text-lg font-semibold text-ovcs-text">
        OVCS <span className="font-normal text-ovcs-muted">{product}</span>
      </h1>
      {children}
      <div className="ml-auto flex flex-wrap items-center justify-end gap-5">
        <BoardFacts board={board} />
        <FirmwareFacts firmware={firmware} />
        <OvcsThemeSwitch />
      </div>
    </OvcsHeader>
  )
}
