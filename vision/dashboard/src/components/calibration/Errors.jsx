import { useCalibration } from '../../stores/calibration.js'
import { BUTTON } from '../../styles.js'

/** An action the API refused, until dismissed. */
export function ActionError() {
  const error = useCalibration((state) => state.error)
  const dismissError = useCalibration((state) => state.dismissError)

  return error ? (
    <div role="alert" className="flex items-center gap-2 rounded border border-ovcs-error px-2 py-1 text-sm">
      <p className="ovcs-status ovcs-status--error min-w-0 flex-1 break-words text-ovcs-error-text">{error}</p>
      <button type="button" aria-label="Dismiss error" onClick={dismissError} className={BUTTON}>
        Dismiss
      </button>
    </div>
  ) : null
}

/** What the unit reports of the session's last solve or apply, until the next one. */
export function SessionError() {
  const error = useCalibration((state) => state.session?.error ?? null)

  return error ? (
    <p role="alert" className="ovcs-status ovcs-status--error text-sm text-ovcs-error-text">
      {error}
    </p>
  ) : null
}
