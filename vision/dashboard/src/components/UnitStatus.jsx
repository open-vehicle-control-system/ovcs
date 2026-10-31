import { OvcsStatus } from '@ovcs/ui/react'
import { unitStatus } from '../status.js'
import Hint from './Hint.jsx'

/** A status item's value with its health dot, and its detail below. */
export function StatusValue({ item, className = 'text-base' }) {
  return (
    <>
      <OvcsStatus tone={item.healthy ? 'ok' : 'error'} className={`font-semibold tabular-nums ${className}`}>
        {item.value}
      </OvcsStatus>
      {item.detail ? <p className="text-xs text-ovcs-muted tabular-nums">{item.detail}</p> : null}
    </>
  )
}

/** The unit's links and load, inline for the top bar, each explained by its hint. */
export default function UnitStatus({ status }) {
  if (!status) return <p className="text-sm text-ovcs-muted">Waiting for the vision unit…</p>

  return (
    <ul aria-label="Unit status" className="flex flex-wrap items-center gap-x-5 gap-y-1 text-sm">
      {unitStatus(status).map((item) => (
        <li key={item.id} data-card={item.id} className="flex items-center gap-2">
          <span className="flex items-center gap-1 text-ovcs-muted">
            {item.title}
            <Hint hint={item.hint} />
          </span>
          <OvcsStatus tone={item.healthy ? 'ok' : 'error'} className="font-medium tabular-nums">
            {item.value}
          </OvcsStatus>
        </li>
      ))}
    </ul>
  )
}
