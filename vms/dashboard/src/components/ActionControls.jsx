import { useEffect, useRef, useState } from 'react'
import { focusClass as FOCUS } from '@ovcs/ui/react'
import { liveValue } from '../format.js'
import { postAction } from '../services/api.js'
import { useMetrics } from '../stores/metrics.js'

const BUTTON = `min-h-8 rounded border border-ovcs-accent px-3 text-sm font-semibold enabled:hover:bg-ovcs-bg disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`

/** Posts a row's action: `pending` while in flight, `error` holding a refusal until the next attempt. */
export function useActionPost(row) {
  const [pending, setPending] = useState(false)
  const [error, setError] = useState(null)

  const post = (value) => {
    setError(null)
    setPending(true)
    postAction(row, value)
      .catch((reason) => {
        console.error(`Action ${row.action} failed:`, reason)
        setError(reason.message)
      })
      .finally(() => setPending(false))
  }

  return { post, pending, error }
}

const useStatusValue = (row) =>
  useMetrics((state) => (row.statusMetricKey ? state.data[row.module]?.[row.statusMetricKey] : undefined))

/** A button that triggers the action. */
export function ButtonAction({ row, action }) {
  return (
    <button type="button" disabled={action.pending} onClick={() => action.post()} className={BUTTON}>
      {row.inputName}
    </button>
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
      <button type="button" disabled={action.pending} onClick={submit} className={BUTTON}>
        {row.inputName}
      </button>
    </div>
  )
}

/** A switch that is on while the row's status metric is true; clicking it triggers the action. */
export function ToggleAction({ row, action }) {
  const published = useMetrics((state) => state.data[row.module] !== undefined)
  const on = Boolean(useStatusValue(row))

  if (!published) return null

  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={row.name}
      disabled={action.pending}
      onClick={() => action.post()}
      className={`inline-flex w-9 rounded-full p-0.5 transition-colors disabled:opacity-50 ${on ? 'bg-ovcs-accent' : 'bg-ovcs-border'} ${FOCUS}`}
    >
      <span
        aria-hidden="true"
        className={`size-4 rounded-full bg-ovcs-surface shadow transition-transform ${on ? 'translate-x-4' : 'translate-x-0'}`}
      />
    </button>
  )
}
