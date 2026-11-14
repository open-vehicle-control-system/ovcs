import { useEffect, useRef, useState } from 'react'
import { OvcsDialog } from '@ovcs/ui/react'
import InUse from '../components/calibration/InUse.jsx'
import Saved from '../components/calibration/Saved.jsx'
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

/**
 * One calibration, the one the menu opened and names: the one the unit uses, and in a dialog the steps that make a new
 * one from views of a chessboard. The dialog opens from the page's button and stays while a session runs, which only
 * its own buttons end; once closed, the focus goes back to that button. Joining the calibration channel turns board
 * detection on in the unit, so only this page joins it, while mounted.
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
  const close = running ? null : () => setOpened(false)

  useEffect(() => listen(dashboardSocket), [listen])

  useEffect(() => {
    if (calibrationId != null) select(calibrationId)
  }, [calibrationId, select])

  // A session that started keeps the dialog open by itself, and closes it when it ends.
  useEffect(() => {
    if (running) setOpened(false)
  }, [running])

  return (
    <div className="flex min-w-0 flex-col gap-4">
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
          <Saved />
          {shown ? (
            <OvcsDialog
              aria-label="Calibrate"
              onClose={close}
              returnFocus={calibrate}
              className="max-w-7xl"
            >
              <FlowClose value={close}>
                <ActionError />
                <Step phase={phase} />
              </FlowClose>
            </OvcsDialog>
          ) : null}
        </>
      )}
      {shown ? null : <ActionError />}
    </div>
  )
}
