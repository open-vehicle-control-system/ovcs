import { useCallback, useEffect, useId, useRef, useState } from 'react'
import OvcsButton from './OvcsButton.jsx'
import OvcsCard from './OvcsCard.jsx'
import OvcsDialog from './OvcsDialog.jsx'

function Confirmation({ title, message, confirmLabel, danger, onAnswer }) {
  const titleId = useId()
  const messageId = useId()

  return (
    <OvcsDialog
      role="alertdialog"
      aria-labelledby={titleId}
      aria-describedby={message ? messageId : undefined}
      onClose={() => onAnswer(false)}
      align="center"
      className="max-w-md"
    >
      <OvcsCard className="flex flex-col gap-3">
        <h2 id={titleId} className="font-semibold">
          {title}
        </h2>
        {message ? (
          <p id={messageId} className="text-sm text-ovcs-muted">
            {message}
          </p>
        ) : null}
        <div className="flex flex-wrap justify-end gap-2">
          <OvcsButton autoFocus onClick={() => onAnswer(false)}>
            Cancel
          </OvcsButton>
          <OvcsButton variant={danger ? 'danger' : 'primary'} onClick={() => onAnswer(true)}>
            {confirmLabel}
          </OvcsButton>
        </div>
      </OvcsCard>
    </OvcsDialog>
  )
}

/**
 * Asks before an action, in an `OvcsDialog` rather than the browser's own: returns `[confirm, confirmation]`, where
 * `confirm({ title, message, confirmLabel, danger })` shows the question `title`, with `message` under it, Cancel
 * (focused) and `confirmLabel`, in the error colour when `danger`, and resolves to whether it was confirmed. Escape
 * cancels. Render `confirmation` in the component; a question left unanswered when it goes, or when another is asked,
 * resolves to `false`.
 */
export function useOvcsConfirm() {
  const [question, setQuestion] = useState(null)
  const asked = useRef(null)

  const confirm = useCallback(
    (options) =>
      new Promise((resolve) => {
        asked.current?.resolve(false)
        asked.current = { ...options, resolve }
        setQuestion(asked.current)
      }),
    []
  )

  const answer = useCallback((confirmed) => {
    asked.current?.resolve(confirmed)
    asked.current = null
    setQuestion(null)
  }, [])

  useEffect(() => () => asked.current?.resolve(false), [])

  const confirmation = question ? (
    <Confirmation
      title={question.title}
      message={question.message}
      confirmLabel={question.confirmLabel}
      danger={question.danger}
      onAnswer={answer}
    />
  ) : null

  return [confirm, confirmation]
}
