import { useEffect } from 'react'
import { OvcsPageFrame } from '@ovcs/ui/react'
import InUse from '../components/calibration/InUse.jsx'
import Targets from '../components/calibration/Targets.jsx'
import { BoardForm, Capturing, Solving } from '../components/calibration/Capture.jsx'
import { Applying, Solved } from '../components/calibration/Result.jsx'
import { ActionError } from '../components/calibration/Errors.jsx'
import { useCalibration } from '../stores/calibration.js'
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
 * The cameras' calibration: the one in use, and a new one from views of a chessboard. Joining the calibration channel
 * turns board detection on in the unit, so only this page joins it, while mounted.
 */
export default function CalibrationPage() {
  const listen = useCalibration((state) => state.listen)
  const unavailable = useCalibration((state) => state.unavailable)
  const phase = useCalibration((state) => state.session?.phase ?? null)
  const uncalibrated = useStatus((state) => state.snapshot?.calibrated === false)

  useEffect(() => listen(dashboardSocket), [listen])

  return (
    <OvcsPageFrame title="Calibration" summary="The calibration the cameras use, and a new one from views of a chessboard.">
      {uncalibrated ? (
        <p className="ovcs-status ovcs-status--warn text-sm text-ovcs-warn-text">
          The unit is uncalibrated: depth starts once a calibration is applied.
        </p>
      ) : null}
      <ActionError />
      {unavailable ? (
        <p className="text-sm text-ovcs-muted">This unit has no camera to calibrate.</p>
      ) : (
        <>
          <Targets />
          <InUse />
          <Step phase={phase} />
        </>
      )}
    </OvcsPageFrame>
  )
}
