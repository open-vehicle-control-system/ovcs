import { useEffect, useId, useRef, useState } from 'react'
import { FOCUS } from './styles.js'

const BUTTON = `min-h-9 rounded border border-ovcs-border px-3 text-sm enabled:hover:border-ovcs-accent disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`
const PRIMARY = `${BUTTON} enabled:border-ovcs-accent font-semibold`

const COPIED_MS = 2000

const changes = (count, kind = '') => `${count} ${kind}${count === 1 ? 'change' : 'changes'}`

const message = (error) => (error instanceof Error ? error.message : String(error))

function ExportSnippet({ snippet, onClose }) {
  const headingId = useId()
  const snippetRef = useRef(null)
  const [copy, setCopy] = useState('')

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
      setCopy(copyBySelection() ? 'Copied' : 'Press Ctrl+C to copy')
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
          Copy
        </button>
        <button type="button" aria-label="Close export" onClick={onClose} className={BUTTON}>
          Close
        </button>
      </div>
      <pre ref={snippetRef} translate="no" className="max-h-64 overflow-auto rounded border border-ovcs-border bg-ovcs-bg p-3 font-mono text-xs">
        {snippet}
      </pre>
    </section>
  )
}

/**
 * The unsaved count with Save and Discard, Reset all, Export and the last error.
 * `onExport` resolves to the snippet it shows.
 */
export default function SaveBar({ unsaved, error, onSave, onDiscard, onResetAll, onExport, onDismissError }) {
  const [snippet, setSnippet] = useState(null)
  const [exportError, setExportError] = useState(null)

  const discard = () => {
    if (window.confirm(`Discard ${changes(unsaved, 'unsaved ')}?`)) onDiscard()
  }

  const resetAll = () => {
    const question =
      unsaved > 0
        ? `Reset every parameter to its default? This also drops ${changes(unsaved, 'unsaved ')}.`
        : 'Reset every parameter to its default?'
    if (window.confirm(question)) onResetAll()
  }

  const exportSnippet = async () => {
    try {
      setSnippet(await onExport())
      setExportError(null)
    } catch (failure) {
      setExportError(`Export failed: ${message(failure)}`)
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <p aria-live="polite" className="mr-auto text-sm tabular-nums">
          {unsaved > 0 ? changes(unsaved, 'unsaved ') : 'No unsaved changes'}
        </p>
        <button type="button" disabled={unsaved === 0} onClick={onSave} className={`${PRIMARY} tabular-nums`}>
          {unsaved > 0 ? `Save ${changes(unsaved)}` : 'Save'}
        </button>
        <button type="button" disabled={unsaved === 0} onClick={discard} className={BUTTON}>
          Discard
        </button>
        <button type="button" onClick={resetAll} className={BUTTON}>
          Reset all
        </button>
        <button type="button" onClick={exportSnippet} className={BUTTON}>
          Export
        </button>
      </div>
      {error || exportError ? (
        <div role="alert" className="flex items-start gap-2 rounded border border-ovcs-error p-2 text-sm">
          <p className="ovcs-status ovcs-status--error min-w-0 flex-1 break-words">
            <span className="text-ovcs-text">{error ?? exportError}</span>
          </p>
          <button
            type="button"
            aria-label="Dismiss error"
            onClick={error ? onDismissError : () => setExportError(null)}
            className={BUTTON}
          >
            Dismiss
          </button>
        </div>
      ) : null}
      {snippet != null ? <ExportSnippet snippet={snippet} onClose={() => setSnippet(null)} /> : null}
    </div>
  )
}
