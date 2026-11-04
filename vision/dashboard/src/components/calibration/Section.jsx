import { useId } from 'react'
import { OvcsCard } from '@ovcs/ui/react'

/** A card named by its heading, for the page's parts. */
export default function Section({ title, children }) {
  const headingId = useId()

  return (
    <OvcsCard as="section" aria-labelledby={headingId} className="flex min-w-0 flex-col gap-3">
      <h3 id={headingId} className="font-semibold">
        {title}
      </h3>
      {children}
    </OvcsCard>
  )
}
