import { useEffect, useRef, useState } from 'react'
import InUse from '../components/calibration/InUse.jsx'
import { BoardForm, Capturing, Solving } from '../components/calibration/Capture.jsx'
import { Applying, Solved } from '../components/calibration/Result.jsx'
import { ActionError } from '../components/calibration/Errors.jsx'
import { FlowClose } from '../components/calibration/Flow.jsx'
import { useCalibration } from '../stores/calibration.js'
import { useNavigation } from '../stores/navigation.js'
import { useStatus } from '../stores/status.js'
import { dashboardSocket } from '../services/socket.js'

/** The session's step: the board, the capture, the solve, then its result. */
function Step({ phase }) {
  return phase === 'idle' ? (
    <BoardForm />
  ) : phase === 'capturing' ? (
    <Capturing socket={dashboardSocket} />
  ) : phase === 'solving' ? (
    <Solving />
  ) : phase === 'solved' ? (
    <Solved />
  ) : phase === 'applying' ? (
    <Applying />
  ) : (
    <p className="text-sm text-ovcs-muted">Waiting for the calibration session…</p>
  )
}

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

/**
 * The steps in a dialog over the page, which keeps the focus: Tab goes round its controls, and the focus comes back
 * to it when the control that had it goes with a step. Escape closes it where `onClose` is given.
 */
function Dialog({ onClose, children }) {
  const dialog = useRef(null)

  // After each render: a step that ended took the focused control with it.
  useEffect(() => {
    if (!dialog.current.contains(document.activeElement)) dialog.current.focus()
  })

  useEffect(() => {
    const onKeyDown = (event) => {
      if (event.key === 'Escape' && onClose) {
        onClose()
      } else if (event.key === 'Tab') {
        const controls = [...dialog.current.querySelectorAll(FOCUSABLE)]
        const first = controls[0] ?? dialog.current
        const last = controls.at(-1) ?? dialog.current
        const active = document.activeElement
        const outside = !dialog.current.contains(active)

        if (event.shiftKey ? outside || active === first || active === dialog.current : outside || active === last) {
          event.preventDefault()
          ;(event.shiftKey ? last : first).focus()
        }
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-30 flex items-start justify-center overflow-y-auto bg-black/60 p-4 [overscroll-behavior:contain] lg:p-8">
      <div ref={dialog} role="dialog" aria-modal="true" aria-label="Calibrate" tabIndex={-1} className="w-full max-w-7xl outline-none">
        <FlowClose value={onClose}>{children}</FlowClose>
      </div>
    </div>
  )
}

/**
 * One calibration, the one the menu opened and names: the one the unit uses, and in a dialog the steps that make a new
 * one from views of a chessboard. The dialog opens from the page's button and stays while a session runs, which only
 * its own buttons end. Joining the calibration channel turns board detection on in the unit, so only this page joins
 * it, while mounted.
 */
export default function CalibrationPage() {
  const listen = useCalibration((state) => state.listen)
  const select = useCalibration((state) => state.select)
  const unavailable = useCalibration((state) => state.unavailable)
  const phase = useCalibration((state) => state.session?.phase ?? null)
  const calibrationId = useNavigation((state) => state.calibrationId)
  const uncalibrated = useStatus((state) => state.snapshot?.calibrated === false)
  const [opened, setOpened] = useState(false)
  const running = phase != null && phase !== 'idle'
  const shown = !unavailable && (opened || running)
  const calibrate = useRef(null)
  const wasShown = useRef(false)

  useEffect(() => listen(dashboardSocket), [listen])

  useEffect(() => {
    if (calibrationId != null) select(calibrationId)
  }, [calibrationId, select])

  // A session that started keeps the dialog open by itself, and closes it when it ends.
  useEffect(() => {
    if (running) setOpened(false)
  }, [running])

  // The dialog that closed gives the focus back to the button that opens it.
  useEffect(() => {
    if (wasShown.current && !shown) calibrate.current?.focus()
    wasShown.current = shown
  }, [shown])

  return (
    <div className="flex min-w-0 flex-col gap-4 lg:min-h-0 lg:overflow-y-auto">
      {uncalibrated ? (
        <p className="ovcs-status ovcs-status--warn text-sm text-ovcs-warn-text">
          The unit is uncalibrated: depth starts once a calibration is applied.
        </p>
      ) : null}
      {unavailable ? (
        <p className="text-sm text-ovcs-muted">This unit has no camera to calibrate.</p>
      ) : (
        <>
          <InUse onCalibrate={phase === 'idle' ? () => setOpened(true) : undefined} calibrateRef={calibrate} />
          {shown ? (
            <Dialog onClose={running ? null : () => setOpened(false)}>
              <ActionError />
              <Step phase={phase} />
            </Dialog>
          ) : null}
        </>
      )}
      {shown ? null : <ActionError />}
    </div>
  )
}
