import { useState } from 'react'
import { FOCUS } from './styles.js'

const BUTTON = `min-h-9 rounded border border-ovcs-border px-3 text-sm enabled:hover:border-ovcs-accent disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`
const PRIMARY = `${BUTTON} enabled:border-ovcs-accent font-semibold`

const RUNNING = { save: 'Saving…', discard: 'Discarding…', reset: 'Resetting…' }

const changes = (count, kind = '') => `${count} ${kind}${count === 1 ? 'change' : 'changes'}`

function Alert({ text, dismissLabel, onDismiss }) {
  return (
    <div role="alert" className="flex items-start gap-2 rounded border border-ovcs-error p-2 text-sm">
      <p className="ovcs-status ovcs-status--error min-w-0 flex-1 break-words">
        <span className="text-ovcs-text">{text}</span>
      </p>
      <button type="button" aria-label={dismissLabel} onClick={onDismiss} className={BUTTON}>
        Dismiss
      </button>
    </div>
  )
}

/**
 * The unsaved count with Save and Discard, Reset all and the errors.
 *
 * The callbacks may return promises; the actions stay disabled until they settle. `className` and
 * `ref` go to the bar itself.
 */
export default function OvcsSaveBar({
  unsaved,
  error,
  onSave,
  onDiscard,
  onResetAll,
  onDismissError,
  className = '',
  ref
}) {
  const [running, setRunning] = useState(null)

  const run = async (name, action) => {
    setRunning(name)
    try {
      await action()
    } catch {
      // The caller reports a failed action through `error`.
    } finally {
      setRunning(null)
    }
  }

  const discard = () => {
    if (window.confirm(`Discard ${changes(unsaved, 'unsaved ')}?`)) run('discard', onDiscard)
  }

  const resetAll = () => {
    const question =
      unsaved > 0
        ? `Reset every parameter to its default? This also drops ${changes(unsaved, 'unsaved ')}.`
        : 'Reset every parameter to its default?'
    if (window.confirm(question)) run('reset', onResetAll)
  }

  const label = (name, idle) => (running === name ? RUNNING[name] : idle)

  return (
    <div ref={ref} className={`flex flex-col gap-3 ${className}`}>
      <div className="flex flex-wrap items-center gap-2">
        <p aria-live="polite" className="mr-auto text-sm tabular-nums">
          {unsaved > 0 ? changes(unsaved, 'unsaved ') : 'No unsaved changes'}
        </p>
        <button type="button" disabled={unsaved === 0 || running != null} onClick={() => run('save', onSave)} className={`${PRIMARY} tabular-nums`}>
          {label('save', unsaved > 0 ? `Save ${changes(unsaved)}` : 'Save')}
        </button>
        <button type="button" disabled={unsaved === 0 || running != null} onClick={discard} className={`${BUTTON} tabular-nums`}>
          {label('discard', unsaved > 0 ? `Discard ${changes(unsaved)}` : 'Discard')}
        </button>
        <button type="button" disabled={running != null} onClick={resetAll} className={BUTTON}>
          {label('reset', 'Reset all')}
        </button>
      </div>
      {error ? <Alert text={error} dismissLabel="Dismiss error" onDismiss={onDismissError} /> : null}
    </div>
  )
}
