import { OvcsBottomBarItem, OvcsStatus } from '@ovcs/ui/react'
import { unitStatus } from '../status.js'
import Hint from './Hint.jsx'

const WARNING_ICON = (
  <svg data-warning aria-hidden="true" viewBox="0 0 16 16" className="size-3.5 shrink-0" fill="currentColor">
    <path fillRule="evenodd" d="M8 1 15.5 14.5H.5L8 1Zm-.75 5v4h1.5V6h-1.5Zm0 5.25v1.5h1.5v-1.5h-1.5Z" />
  </svg>
)

// What marks an unhealthy value beyond its colour: a warning sign, and words for a screen reader.
const WARNING = (
  <>
    {WARNING_ICON}
    <span className="sr-only">, unhealthy</span>
  </>
)

/** A value with its health dot; an unhealthy one also gets a warning sign, and words for a screen reader. */
export function HealthValue({ tone, children }) {
  return (
    <>
      {children}
      {tone === 'error' ? WARNING : null}
    </>
  )
}

/** `children` in a box as wide as `widest` in the same font, so what follows keeps its place as the value changes. */
function Widest({ widest, align, children }) {
  return (
    <span
      data-widest={widest}
      className={`inline-grid after:invisible after:content-[attr(data-widest)] after:[grid-area:1/1] ${align === 'end' ? 'justify-items-end' : ''}`}
    >
      <span className="[grid-area:1/1]">{children}</span>
    </span>
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

/** The unit's links and load, as the bottom bar's items, each explained by its hint; a value changing does not move the line. */
export default function UnitStatus({ status }) {
  return (
    <>
      {unitStatus(status).map((item) => {
        const tone = item.tone ?? (item.healthy ? 'ok' : 'error')
        return (
          <OvcsBottomBarItem
            key={item.id}
            data-card={item.id}
            label={
              <>
                {item.title}
                <Hint hint={item.hint} />
              </>
            }
          >
            <OvcsStatus tone={tone} className="font-medium tabular-nums">
              <Widest widest={item.widest} align={item.align}>
                {item.value}
              </Widest>
              {/* The sign keeps its room while the value is healthy. */}
              <span data-warning-slot className="flex size-3.5 shrink-0">
                {tone === 'error' ? WARNING : null}
              </span>
            </OvcsStatus>
          </OvcsBottomBarItem>
        )
      })}
    </>
  )
}
