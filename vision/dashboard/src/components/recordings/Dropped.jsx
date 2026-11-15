import { useId, useState } from 'react'
import { OvcsStatus, focusClass as FOCUS } from '@ovcs/ui/react'
import { droppedByTopic, droppedText } from './format.js'

/** The messages a recording dropped, as a warning, with each topic's count behind a toggle. */
export default function Dropped({ dropped, messages }) {
  const tableId = useId()
  const [open, setOpen] = useState(false)
  if (!dropped?.length) return droppedText(dropped, messages)

  return (
    <div className="flex min-w-0 flex-col gap-1">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <OvcsStatus tone="warn">{droppedText(dropped, messages)}</OvcsStatus>
        <button
          type="button"
          aria-expanded={open}
          aria-controls={tableId}
          onClick={() => setOpen(!open)}
          className={`inline-flex min-h-6 items-center gap-0.5 rounded text-sm font-normal text-ovcs-accent-text hover:underline ${FOCUS}`}
        >
          by topic
          <svg
            aria-hidden="true"
            viewBox="0 0 16 16"
            fill="currentColor"
            className={`size-3 transition-transform motion-reduce:transition-none ${open ? 'rotate-90' : ''}`}
          >
            <path d="M6 3.5 10.5 8 6 12.5Z" />
          </svg>
        </button>
      </div>
      <table id={tableId} hidden={!open} aria-label="Dropped by topic" className="w-full max-w-xl text-sm font-normal">
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
              <td className="break-all py-0.5 pr-4 font-mono text-xs leading-5">{topic}</td>
              <td className="py-0.5 text-right tabular-nums">{count}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
