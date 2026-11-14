import { useId } from 'react'

/**
 * A part of the page, named by its heading: the tone `warn` colours the heading, `hint` follows it, `subtitle` sits
 * under it and `actions` beside it, or under the subtitle on a narrow screen.
 */
export default function Section({ title, tone, hint, subtitle, actions, className = '', children }) {
  const headingId = useId()

  return (
    <section aria-labelledby={headingId} className={`flex min-w-0 flex-col gap-3 ${className}`}>
      <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
        <div className="flex min-h-9 items-center gap-1">
          <h3 id={headingId} className={`font-semibold ${tone === 'warn' ? 'text-ovcs-warn-text' : ''}`}>
            {title}
          </h3>
          {hint}
        </div>
        {subtitle ? <p className="order-1 -mt-2 basis-full break-words text-sm text-ovcs-muted sm:order-2">{subtitle}</p> : null}
        {actions ? <div className="order-2 sm:order-1">{actions}</div> : null}
      </div>
      {children}
    </section>
  )
}
