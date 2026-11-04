import { useEffect, useRef, useState } from 'react'
import { OvcsButton, OvcsSwitch, focusClass as FOCUS } from '@ovcs/ui/react'
import { liveValue } from '../format.js'
import { postAction } from '../services/api.js'
import { useMetrics } from '../stores/metrics.js'

const SENT_FOR_MS = 2000

/**
 * Posts a row's action: `pending` while in flight, `sent` for two seconds once it is accepted, `error` holding a
 * refusal until the next attempt.
 */
export function useActionPost(row) {
  const [pending, setPending] = useState(false)
  const [sent, setSent] = useState(false)
  const [error, setError] = useState(null)
  const sentTimer = useRef(null)

  useEffect(() => () => clearTimeout(sentTimer.current), [])

  const post = (value) => {
    clearTimeout(sentTimer.current)
    setSent(false)
    setError(null)
    setPending(true)
    postAction(row, value)
      .then(() => {
        setSent(true)
        sentTimer.current = setTimeout(() => setSent(false), SENT_FOR_MS)
      })
      .catch((reason) => {
        console.error(`Action ${row.action} failed:`, reason)
        setError(reason.message)
      })
      .finally(() => setPending(false))
  }

  return { post, pending, sent, error }
}

const useStatusValue = (row) =>
  useMetrics((state) => (row.statusMetricKey ? state.data[row.module]?.[row.statusMetricKey] : undefined))

/** A button that triggers the action. */
export function ButtonAction({ row, action }) {
  return (
    <OvcsButton variant="primary" disabled={action.pending} onClick={() => action.post()}>
      {row.inputName}
    </OvcsButton>
  )
}

/** A number field seeded once with the live value, its "now" badge, and a button that sends the field's value. */
export function NumberAction({ row, action }) {
  const live = liveValue(useStatusValue(row))
  const [field, setField] = useState('')
  const seeded = useRef(false)

  // After the first live value, the field belongs to the operator.
  useEffect(() => {
    if (seeded.current || live === '') return
    seeded.current = true
    setField(live)
  }, [live])

  const submit = () => {
    if (field !== '') action.post(field)
  }

  return (
    <div className="flex items-center justify-end gap-2">
      {live === '' ? null : (
        <span className="rounded bg-ovcs-bg px-2 py-1 text-xs tabular-nums text-ovcs-muted">now {live}</span>
      )}
      <input
        type="number"
        aria-label={row.name}
        step={row.step || '0.01'}
        value={field}
        placeholder={live}
        onChange={(event) => setField(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter') submit()
        }}
        className={`w-24 rounded border border-ovcs-border bg-ovcs-bg px-2 py-1 text-right text-sm tabular-nums ${FOCUS}`}
      />
      <OvcsButton variant="primary" disabled={action.pending} onClick={submit}>
        {row.inputName}
      </OvcsButton>
    </div>
  )
}

/** A switch that is on while the row's status metric is true; clicking it triggers the action. */
export function ToggleAction({ row, action }) {
  const published = useMetrics((state) => state.data[row.module] !== undefined)
  const on = Boolean(useStatusValue(row))

  if (!published) return null

  return <OvcsSwitch checked={on} label={row.name} disabled={action.pending} onClick={() => action.post()} />
}
