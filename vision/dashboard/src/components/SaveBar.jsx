import { forwardRef, useEffect, useId, useRef, useState } from 'react'
import { FOCUS } from './styles.js'

const BUTTON = `min-h-9 rounded border border-ovcs-border px-3 text-sm enabled:hover:border-ovcs-accent disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`
const PRIMARY = `${BUTTON} enabled:border-ovcs-accent font-semibold`

const COPIED_MS = 2000

const RUNNING = { save: 'Saving…', discard: 'Discarding…', reset: 'Resetting…' }

const changes = (count, kind = '') => `${count} ${kind}${count === 1 ? 'change' : 'changes'}`

const message = (error) => (error instanceof Error ? error.message : String(error))

function ExportSnippet({ snippet, request, onClose }) {
  const headingId = useId()
  const snippetRef = useRef(null)
  const [copy, setCopy] = useState('')

  useEffect(() => {
    snippetRef.current.focus()
    snippetRef.current.scrollIntoView?.({ block: 'nearest' })
  }, [request])

  useEffect(() => {
    if (copy !== 'Copied') return undefined
    const timer = setTimeout(() => setCopy(''), COPIED_MS)
    return () => clearTimeout(timer)
  }, [copy])

  // The clipboard API exists only in secure contexts; the unit serves plain HTTP.
  const copyBySelection = () => {
    window.getSelection().selectAllChildren(snippetRef.current)
    return document.execCommand('copy')
  }

  const copySnippet = async () => {
    try {
      await navigator.clipboard.writeText(snippet)
      setCopy('Copied')
    } catch {
      setCopy(copyBySelection() ? 'Copied' : 'Press Ctrl+C (⌘C on Mac) to copy')
    }
  }

  return (
    <section aria-labelledby={headingId} className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2">
        <h3 id={headingId} className="text-sm font-semibold">
          Saved values as a composer snippet
        </h3>
        <span role="status" className="text-sm text-ovcs-muted">
          {copy}
        </span>
        <button type="button" onClick={copySnippet} className={`${BUTTON} ml-auto`}>
          Copy snippet
        </button>
        <button type="button" aria-label="Close export" onClick={onClose} className={BUTTON}>
          Close
        </button>
      </div>
      <pre
        ref={snippetRef}
        tabIndex={-1}
        translate="no"
        className={`max-h-64 overflow-auto rounded border border-ovcs-border bg-ovcs-bg p-3 font-mono text-xs ${FOCUS}`}
      >
        {snippet}
      </pre>
    </section>
  )
}

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
 * The unsaved count with Save and Discard, Reset all, Export and the errors.
 *
 * The callbacks may return promises; the actions stay disabled until they settle. `onExport`
 * resolves to the snippet, shown above the bar. `className` and `ref` go to the bar itself.
 */
const SaveBar = forwardRef(function SaveBar(
  { unsaved, error, onSave, onDiscard, onResetAll, onExport, onDismissError, className = '' },
  ref
) {
  const [snippet, setSnippet] = useState(null)
  const [exportError, setExportError] = useState(null)
  const [running, setRunning] = useState(null)
  const [exportRequest, setExportRequest] = useState(0)

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

  const exportSnippet = async () => {
    try {
      setSnippet(await onExport())
      setExportRequest((count) => count + 1)
      setExportError(null)
    } catch (failure) {
      setExportError(`Export failed: ${message(failure)}`)
    }
  }

  const label = (name, idle) => (running === name ? RUNNING[name] : idle)

  return (
    <>
      {snippet != null ? <ExportSnippet snippet={snippet} request={exportRequest} onClose={() => setSnippet(null)} /> : null}
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
          <button type="button" onClick={exportSnippet} className={BUTTON}>
            Export
          </button>
        </div>
        {error ? <Alert text={error} dismissLabel="Dismiss error" onDismiss={onDismissError} /> : null}
        {exportError ? <Alert text={exportError} dismissLabel="Dismiss export error" onDismiss={() => setExportError(null)} /> : null}
      </div>
    </>
  )
})

export default SaveBar
