import { OvcsCard, OvcsPageFrame, OvcsStatus } from '@ovcs/ui/react'
import { Fragment } from 'react'

import { LEVEL_TONE } from './statusDot'

const SUMMARIES = {
  mqtt: 'Publishes every signal to the broker, retained, on a topic of its own.',
  http: 'Serves the API, the live channels and this dashboard.'
}

// The attributes an adapter may have beyond its name and status, in the order they read best.
const DETAILS = [
  ['broker', 'Broker'],
  ['clientId', 'Client id'],
  ['topic', 'Topics'],
  ['port', 'Port'],
  ['clients', 'Signal streams open'],
  ['module', 'Module']
]

/** An adapter's status and what it is set up with, from the `status` channel; `adapters` is `null` until it answers. */
export default function AdapterPage({ id, adapters }) {
  if (adapters == null) return <p className="text-ovcs-muted">Loading adapters…</p>

  const adapter = adapters.find((entry) => entry.id === id)
  if (!adapter) return <p className="text-ovcs-muted">The gateway has no adapter {id}.</p>

  return (
    <OvcsPageFrame title={adapter.name} summary={SUMMARIES[adapter.id]}>
      <OvcsCard className="flex flex-col gap-3">
        <OvcsStatus tone={LEVEL_TONE[adapter.status.level]} className="font-medium">
          {adapter.status.detail}
        </OvcsStatus>
        <dl className="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-1.5 text-sm">
          {DETAILS.filter(([key]) => adapter[key] != null).map(([key, label]) => (
            <Fragment key={key}>
              <dt className="text-ovcs-muted">{label}</dt>
              <dd className="break-words font-mono tabular-nums" translate="no">
                {adapter[key]}
              </dd>
            </Fragment>
          ))}
        </dl>
      </OvcsCard>
    </OvcsPageFrame>
  )
}
