import { OvcsStatus } from '@ovcs/ui/react'
import { WARNING, Widest } from './UnitStatus.jsx'
import Hint from './Hint.jsx'
import { PAIR_CHECKS, pairStatus } from '../status.js'

// The gauge's track spans twice a check's threshold toward each camera; its middle half is healthy.
const GAUGE_SPAN = 2

/** Where a check stands, as the unit places it: a cursor on a track from the left camera to the right one. */
function Gauge({ value, tone }) {
  const position = value == null ? null : 50 + (Math.max(-GAUGE_SPAN, Math.min(GAUGE_SPAN, value)) / GAUGE_SPAN) * 50

  return (
    <div data-gauge className="flex items-center gap-1 text-[10px] font-medium text-ovcs-muted">
      <span aria-hidden="true">L</span>
      <div className="relative h-3 flex-1">
        <div className="absolute inset-x-0 top-1/2 h-1 -translate-y-1/2 rounded-full bg-ovcs-border" />
        <div className="absolute left-1/4 right-1/4 top-1/2 h-1 -translate-y-1/2 rounded-full bg-ovcs-ok opacity-40" />
        <div className="absolute left-1/2 top-0 h-3 w-px bg-ovcs-muted" />
        {position == null ? null : (
          <div
            data-cursor
            style={{ left: `${position}%` }}
            className={`absolute top-1/2 size-3 -translate-x-1/2 -translate-y-1/2 rounded-full ring-2 ring-ovcs-surface ${
              tone === 'error' ? 'bg-ovcs-warn' : 'bg-ovcs-ok'
            }`}
          />
        )}
      </div>
      <span aria-hidden="true">R</span>
    </div>
  )
}

// One check in three lines that keep their size: its value, as wide as its widest form, its gauge, then its short
// detail; more figures and its issues on hover.
function PairCheck({ item }) {
  const tone = item.tone ?? (item.healthy ? 'ok' : 'error')
  const title = [item.more, ...item.issues].filter(Boolean).join('\n')

  return (
    <li data-card={item.id} title={title || undefined} className="flex flex-col gap-0.5">
      <div className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-1 text-xs font-medium text-ovcs-muted">
          {item.title}
          <Hint hint={item.hint} />
        </span>
        <OvcsStatus tone={tone} className="font-semibold tabular-nums">
          <Widest widest={item.widest} align="end">
            {item.value}
          </Widest>
          {/* The sign keeps its room while the check is healthy. */}
          <span data-warning-slot className="flex size-3.5 shrink-0">
            {tone === 'error' ? WARNING : null}
          </span>
        </OvcsStatus>
      </div>
      <Gauge value={item.gauge} tone={tone} />
      <span data-detail className="h-4 truncate text-xs text-ovcs-muted tabular-nums">
        {item.detail || '\u00a0'}
      </span>
    </li>
  )
}

/** How the cameras work together, as the unit judges them, one line a check between their previews; a dash until the first status. */
export default function PairStatus({ status }) {
  const items = status ? pairStatus(status) : PAIR_CHECKS.map((check) => ({ ...check, value: '–', tone: 'muted', issues: [] }))

  return (
    <ul aria-label="Camera pair" className="row-span-3 flex w-52 flex-col gap-3 self-center">
      {items.map((item) => (
        <PairCheck key={item.id} item={item} />
      ))}
    </ul>
  )
}
