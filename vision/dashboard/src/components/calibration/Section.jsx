import { useId } from 'react'

/**
 * A part of the page, named by its heading: the tone `warn` colours the heading, `hint` follows it and `actions` sit
 * beside it.
 */
export default function Section({ title, tone, hint, actions, className = '', children }) {
  const headingId = useId()

  return (
    <section aria-labelledby={headingId} className={`flex min-w-0 flex-col gap-3 ${className}`}>
      <div className="flex min-h-9 flex-wrap items-start justify-between gap-x-4 gap-y-2">
        <div className="flex items-center gap-1">
          <h3 id={headingId} className={`font-semibold ${tone === 'warn' ? 'text-ovcs-warn-text' : ''}`}>
            {title}
          </h3>
          {hint}
        </div>
        {actions}
      </div>
      {children}
    </section>
  )
}
