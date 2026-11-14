import { useEffect, useId, useRef, useState } from 'react'
import { boardClock, boardInterfaces, boardLoad } from './board.js'
import OvcsButton from './OvcsButton.jsx'
import OvcsHeader from './OvcsHeader.jsx'
import OvcsStatus from './OvcsStatus.jsx'
import OvcsThemeSwitch from './OvcsThemeSwitch.jsx'
import { reloadPage } from './page.js'
import { useOvcsProduct } from './product.js'
import { FOCUS, classNames } from './styles.js'

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

const SUMMARY = 'flex flex-wrap items-baseline gap-x-5 gap-y-1 text-xs'
const DETAILS = 'flex flex-col gap-1.5 text-xs'

/** One fact: its label, then its value, whose figures keep their width as they change; `spread`, the two at the ends of its line. */
function Fact({ label, title, className, spread = false, children }) {
  return (
    <div className={classNames('flex items-baseline', spread ? 'justify-between gap-4' : 'gap-1.5')} title={title}>
      <dt className="text-ovcs-muted">{label}</dt>
      <dd className={classNames('flex items-baseline gap-1.5 font-medium tabular-nums text-ovcs-text', className)}>{children}</dd>
    </div>
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

/** The board's clock, ticking, with its synchronization. */
function Clock({ board }) {
  const clock = boardClock(board, useNow())

  return (
    <Fact label="Clock">
      <span className="font-mono">{clock.time}</span>
      {clock.state && <OvcsStatus tone={clock.tone}>{clock.state}</OvcsStatus>}
    </Fact>
  )
}

/** What the bar always shows: the vehicle, the board's CPU busy share, its memory in use and its clock. */
function Summary({ firmware, board }) {
  const load = boardLoad(board)
  const cpu = load?.cpu
  if (!firmware?.vehicle && !board) return null

  return (
    <dl aria-label="Summary" className={SUMMARY}>
      {firmware?.vehicle && <Fact label="Vehicle">{firmware.vehicle}</Fact>}
      {cpu && (
        <Fact label="CPU">
          <OvcsStatus tone={load.tone} className="min-w-[5ch]">
            {cpu}
          </OvcsStatus>
        </Fact>
      )}
      {load?.memory && (
        <Fact label="Memory" title="Share of the memory in use">
          <OvcsStatus tone={load.memoryTone} className="min-w-[5ch]">
            {load.memory}
          </OvcsStatus>
        </Fact>
      )}
      {board && <Clock board={board} />}
    </dl>
  )
}

/** The rest, as `[group, facts]`: the board's interfaces and load averages, the firmware's version and system. */
function details(firmware, board) {
  const load = boardLoad(board)?.load
  const boardFacts = [
    ...boardInterfaces(board).map(([name, addresses]) => ({ label: name, value: addresses })),
    ...(load ? [{ label: 'Load', value: load, title: 'Load averages over 1, 5 and 15 minutes' }] : [])
  ]
  const firmwareRest = firmwareFacts(firmware)
    .filter(([label]) => label !== 'Vehicle')
    .map(([label, value]) => ({ label, value }))

  return [
    ['Board', boardFacts],
    ['Firmware', firmwareRest]
  ].filter(([, facts]) => facts.length > 0)
}

const INFO = (
  <svg aria-hidden="true" viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
    <circle cx="12" cy="12" r="9.5" />
    <path d="M12 11v6M12 7.2v.1" />
  </svg>
)

/** A button that opens the details under the bar, at its end; Escape, a press outside or the focus leaving closes them. */
function Details({ groups }) {
  const [open, setOpen] = useState(false)
  const panelId = useId()
  const container = useRef(null)

  useEffect(() => {
    if (!open) return undefined
    const onKey = (event) => {
      if (event.key === 'Escape') setOpen(false)
    }
    const onPress = (event) => {
      if (!container.current?.contains(event.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('pointerdown', onPress)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('pointerdown', onPress)
    }
  }, [open])

  return (
    <div
      ref={container}
      className="flex"
      onBlur={(event) => {
        if (event.relatedTarget && !event.currentTarget.contains(event.relatedTarget)) setOpen(false)
      }}
    >
      <button
        type="button"
        aria-label="Board and firmware details"
        title="Board and firmware details"
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        onClick={() => setOpen((current) => !current)}
        className={`flex size-7 items-center justify-center rounded-full border border-ovcs-border text-ovcs-muted hover:border-ovcs-accent hover:text-ovcs-text ${FOCUS} ${
          open ? 'border-ovcs-accent text-ovcs-text' : ''
        }`}
      >
        {INFO}
      </button>
      {open && (
        <div
          id={panelId}
          className="absolute right-4 top-full z-20 mt-2 flex w-max max-w-[calc(100vw-2rem)] flex-col gap-3 rounded border border-ovcs-border bg-ovcs-surface p-3 shadow-lg lg:right-6"
        >
          {groups.map(([group, facts]) => (
            <dl key={group} aria-label={group} className={DETAILS}>
              {facts.map(({ label, value, title }) => (
                <Fact key={label} label={label} title={title} spread className="break-all font-mono">
                  {value}
                </Fact>
              ))}
            </dl>
          ))}
        </div>
      )}
    </div>
  )
}

/**
 * Whether the unit runs another firmware than the first it answered, as after an upload under the open page: the page
 * is then the previous firmware's.
 */
function useFirmwareChanged(firmware) {
  const revision = firmware?.revision
  const [first, setFirst] = useState(null)

  useEffect(() => {
    if (revision) setFirst((known) => known ?? revision)
  }, [revision])

  return first != null && revision != null && revision !== first
}

function ReloadPrompt() {
  return (
    <div role="status" className="flex min-w-0 items-center gap-2 rounded border border-ovcs-border px-2 py-1 text-sm">
      <p className="ovcs-status ovcs-status--warn min-w-0 text-ovcs-warn-text">
        The unit runs another firmware than this page: reload it.
      </p>
      <OvcsButton onClick={reloadPage} className="shrink-0">
        Reload
      </OvcsButton>
    </div>
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
 * at its end the `firmware`'s vehicle, the `board`'s CPU, memory and clock, as `useOvcsBoard` reads them, a button that opens
 * the rest (the board's interfaces and load averages, the firmware's version and system, from `revision`, `target`,
 * `nervesSystem` and `nervesSystemVersion`) and the `OvcsThemeSwitch`, last; its content wraps on a narrow screen. It
 * titles the browser tab with "OVCS", the product and the vehicle, and offers to reload the page once the firmware's
 * `revision` changes under it.
 */
export default function OvcsTopBar({ firmware, board, className, children, ...props }) {
  const product = useOvcsProduct()
  usePageTitle(product, firmware?.vehicle)
  const groups = details(firmware, board)
  const firmwareChanged = useFirmwareChanged(firmware)

  return (
    <OvcsHeader
      className={classNames('flex min-h-14 shrink-0 flex-wrap items-center gap-x-8 gap-y-2 px-4 py-2 lg:px-6', className)}
      {...props}
    >
      <h1 className="text-lg font-semibold text-ovcs-text">
        OVCS <span className="font-normal text-ovcs-muted">{product}</span>
      </h1>
      {firmwareChanged ? <ReloadPrompt /> : null}
      {children}
      <div className="ml-auto flex flex-wrap items-center justify-end gap-5">
        <Summary firmware={firmware} board={board} />
        {groups.length > 0 && <Details groups={groups} />}
        <OvcsThemeSwitch />
      </div>
    </OvcsHeader>
  )
}
