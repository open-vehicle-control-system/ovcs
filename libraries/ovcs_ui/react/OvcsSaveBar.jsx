import { useState } from 'react'
import OvcsButton from './OvcsButton.jsx'
import { useOvcsConfirm } from './OvcsConfirm.jsx'

const RUNNING = { save: 'Saving…', discard: 'Discarding…', reset: 'Resetting…' }

const changes = (count, kind = '') => `${count} ${kind}${count === 1 ? 'change' : 'changes'}`

function Alert({ text, dismissLabel, onDismiss }) {
  return (
    <div role="alert" className="flex items-start gap-2 rounded border border-ovcs-error p-2 text-sm">
      <p className="ovcs-status ovcs-status--error min-w-0 flex-1 break-words">
        <span className="text-ovcs-text">{text}</span>
      </p>
      <OvcsButton aria-label={dismissLabel} onClick={onDismiss}>
        Dismiss
      </OvcsButton>
    </div>
  )
}

/**
 * The unsaved count with Save and Discard, Reset all and the errors. Discard and Reset all ask first.
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
  const [confirm, confirmation] = useOvcsConfirm()

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

  const discard = async () => {
    const title = `Discard ${changes(unsaved, 'unsaved ')}?`
    if (await confirm({ title, confirmLabel: 'Discard', danger: true })) run('discard', onDiscard)
  }

  const resetAll = async () => {
    const message = unsaved > 0 ? `This also drops ${changes(unsaved, 'unsaved ')}.` : null
    const question = { title: 'Reset every parameter to its default?', message, confirmLabel: 'Reset all', danger: true }
    if (await confirm(question)) run('reset', onResetAll)
  }

  const label = (name, idle) => (running === name ? RUNNING[name] : idle)

  return (
    <div ref={ref} className={`flex flex-col gap-3 ${className}`}>
      <div className="flex flex-wrap items-center gap-2">
        <p aria-live="polite" className="mr-auto text-sm tabular-nums">
          {unsaved > 0 ? changes(unsaved, 'unsaved ') : 'No unsaved changes'}
        </p>
        <OvcsButton
          variant="primary"
          disabled={unsaved === 0 || running != null}
          onClick={() => run('save', onSave)}
          className="tabular-nums"
        >
          {label('save', unsaved > 0 ? `Save ${changes(unsaved)}` : 'Save')}
        </OvcsButton>
        <OvcsButton disabled={unsaved === 0 || running != null} onClick={discard} className="tabular-nums">
          {label('discard', unsaved > 0 ? `Discard ${changes(unsaved)}` : 'Discard')}
        </OvcsButton>
        <OvcsButton disabled={running != null} onClick={resetAll}>
          {label('reset', 'Reset all')}
        </OvcsButton>
      </div>
      {error ? <Alert text={error} dismissLabel="Dismiss error" onDismiss={onDismissError} /> : null}
      {confirmation}
    </div>
  )
}
