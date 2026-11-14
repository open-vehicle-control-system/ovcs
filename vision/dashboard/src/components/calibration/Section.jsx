import { useId } from 'react'
import { OvcsCard } from '@ovcs/ui/react'

/** A card named by its heading, for the page's parts; the tone `warn` colours the heading, and `actions` sit beside it. */
export default function Section({ title, tone, actions, children }) {
  const headingId = useId()

  return (
    <OvcsCard as="section" aria-labelledby={headingId} className="flex min-w-0 flex-col gap-3">
      <div className="flex min-h-9 flex-wrap items-start justify-between gap-x-8 gap-y-2">
        <h3 id={headingId} className={`font-semibold ${tone === 'warn' ? 'text-ovcs-warn-text' : ''}`}>
          {title}
        </h3>
        {actions}
      </div>
      {children}
    </OvcsCard>
  )
}
