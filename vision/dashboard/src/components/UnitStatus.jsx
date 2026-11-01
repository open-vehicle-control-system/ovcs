import { OvcsStatus } from '@ovcs/ui/react'
import { unitStatus } from '../status.js'
import Hint from './Hint.jsx'

const WARNING_ICON = (
  <svg data-warning aria-hidden="true" viewBox="0 0 16 16" className="size-3.5 shrink-0" fill="currentColor">
    <path fillRule="evenodd" d="M8 1 15.5 14.5H.5L8 1Zm-.75 5v4h1.5V6h-1.5Zm0 5.25v1.5h1.5v-1.5h-1.5Z" />
  </svg>
)

/** A value with its health dot; an unhealthy one also gets a warning sign, and words for a screen reader. */
export function HealthValue({ tone, children }) {
  return (
    <>
      {children}
      {tone === 'error' ? (
        <>
          {WARNING_ICON}
          <span className="sr-only">, unhealthy</span>
        </>
      ) : null}
    </>
  )
}

/** A status item's value with its health dot, and its detail below. */
export function StatusValue({ item, className = 'text-base' }) {
  const tone = item.healthy ? 'ok' : 'error'
  return (
    <>
      <OvcsStatus tone={tone} className={`font-semibold tabular-nums ${className}`}>
        <HealthValue tone={tone}>{item.value}</HealthValue>
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
      {unitStatus(status).map((item) => {
        const tone = item.tone ?? (item.healthy ? 'ok' : 'error')
        return (
          <li key={item.id} data-card={item.id} className="flex items-center gap-2">
            <span className="flex items-center gap-1 text-ovcs-muted">
              {item.title}
              <Hint hint={item.hint} />
            </span>
            <OvcsStatus tone={tone} className="font-medium tabular-nums">
              <HealthValue tone={tone}>{item.value}</HealthValue>
            </OvcsStatus>
          </li>
        )
      })}
    </ul>
  )
}
