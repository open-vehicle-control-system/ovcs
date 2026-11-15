import { OvcsStatus, focusClass as FOCUS } from '@ovcs/ui/react'
import { droppedByTopic, droppedShortText, droppedText } from './format.js'

const LINK = `inline-flex min-h-6 items-center gap-0.5 rounded text-sm font-normal hover:underline ${FOCUS}`

function Chevron({ open }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 16 16"
      fill="currentColor"
      className={`size-3 shrink-0 transition-transform motion-reduce:transition-none ${open ? 'rotate-90' : ''}`}
    >
      <path d="M6 3.5 10.5 8 6 12.5Z" />
    </svg>
  )
}

/** Each topic that dropped messages with its count, the most first; hidden while not `open`. */
export function DroppedByTopic({ id, dropped, open }) {
  return (
    <table id={id} hidden={!open} aria-label="Dropped by topic" className="w-full max-w-xl text-sm font-normal">
      <thead>
        <tr className="text-xs text-ovcs-muted">
          <th scope="col" className="py-0.5 pr-4 text-left font-normal">
            topic
          </th>
          <th scope="col" className="py-0.5 text-right font-normal">
            dropped
          </th>
        </tr>
      </thead>
      <tbody className="divide-y divide-ovcs-border">
        {droppedByTopic(dropped).map(({ topic, count }) => (
          <tr key={topic}>
            <td translate="no" className="break-all py-0.5 pr-4 font-mono text-xs leading-5">{topic}</td>
            <td className="py-0.5 text-right tabular-nums">{count}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

/**
 * The messages a recording dropped in short, for a column named dropped: `none`, or a button that opens their counts
 * by topic, the table `controls`, wherever it is.
 */
export function DroppedToggle({ dropped, messages, open, onToggle, controls }) {
  if (!dropped?.length) return <span className="text-ovcs-muted">none</span>

  return (
    <button
      type="button"
      aria-expanded={open}
      aria-controls={controls}
      aria-label={`${droppedText(dropped, messages)} dropped, by topic`}
      onClick={onToggle}
      className={`${LINK} text-ovcs-warn-text`}
    >
      <OvcsStatus tone="warn" className="whitespace-nowrap tabular-nums">
        {droppedShortText(dropped, messages)}
      </OvcsStatus>
      <Chevron open={open} />
    </button>
  )
}

/**
 * The messages a recording dropped, as a warning, with a toggle that opens their counts by topic, the table `controls`,
 * wherever it is; `none` without any.
 */
export function DroppedSummary({ dropped, messages, open, onToggle, controls }) {
  if (!dropped?.length) return droppedText(dropped, messages)

  return (
    <span className="flex flex-wrap items-center gap-x-3 gap-y-1">
      <OvcsStatus tone="warn">{droppedText(dropped, messages)}</OvcsStatus>
      <button
        type="button"
        aria-expanded={open}
        aria-controls={controls}
        onClick={onToggle}
        className={`${LINK} text-ovcs-accent-text`}
      >
        by topic
        <Chevron open={open} />
      </button>
    </span>
  )
}
