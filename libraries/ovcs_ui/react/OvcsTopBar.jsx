import { useEffect, useState } from 'react'
import { boardClock, boardInterfaces, boardLoad } from './board.js'
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

const FACTS = 'flex flex-wrap items-baseline gap-x-5 gap-y-1 text-xs'

/** One fact: its label, then its value, whose figures keep their width as they change. */
function Fact({ label, title, className, children }) {
  return (
    <div className="flex items-baseline gap-1.5" title={title}>
      <dt className="text-ovcs-muted">{label}</dt>
      <dd className={classNames('flex items-baseline gap-1.5 font-medium tabular-nums text-ovcs-text', className)}>{children}</dd>
    </div>
  )
}

/** The firmware's facts, each value after its label, set apart from the board's when they follow them. */
function FirmwareFacts({ firmware, separated }) {
  const facts = firmwareFacts(firmware)
  if (facts.length === 0) return null

  return (
    <dl aria-label="Firmware" className={classNames(FACTS, separated && 'border-l border-ovcs-border pl-5')}>
      {facts.map(([label, value]) => (
        <Fact key={label} label={label} className={label === 'Version' && 'font-mono'}>
          {value}
        </Fact>
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

/**
 * The board's interfaces, each name before its addresses, its CPU's busy share and load averages, then its clock,
 * ticking, with its synchronization.
 */
function BoardFacts({ board }) {
  const now = useNow()
  if (!board) return null
  const load = boardLoad(board)
  const clock = boardClock(board, now)

  return (
    <dl aria-label="Board" className={FACTS}>
      {boardInterfaces(board).map(([name, addresses]) => (
        <Fact key={name} label={name} className="font-mono">
          {addresses}
        </Fact>
      ))}
      {load.cpu && (
        <Fact label="CPU">
          <OvcsStatus tone={load.tone} className="min-w-[5ch]">
            {load.cpu}
          </OvcsStatus>
        </Fact>
      )}
      {load.load && (
        <Fact label="Load" title="Load averages over 1, 5 and 15 minutes" className="font-mono">
          {load.load}
        </Fact>
      )}
      <Fact label="Clock">
        <span className="font-mono">{clock.time}</span>
        {clock.state && <OvcsStatus tone={clock.tone}>{clock.state}</OvcsStatus>}
      </Fact>
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
 * at its end the `board`'s interfaces, load and clock, as `useOvcsBoard` reads them, the `firmware`'s version, system and
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
        <FirmwareFacts firmware={firmware} separated={Boolean(board)} />
        <OvcsThemeSwitch />
      </div>
    </OvcsHeader>
  )
}
