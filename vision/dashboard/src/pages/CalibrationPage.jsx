import { useEffect } from 'react'
import { OvcsPageFrame } from '@ovcs/ui/react'
import InUse from '../components/calibration/InUse.jsx'
import { BoardForm, Capturing, Solving } from '../components/calibration/Capture.jsx'
import { Applying, Solved } from '../components/calibration/Result.jsx'
import { ActionError } from '../components/calibration/Errors.jsx'
import { selectedCalibration, useCalibration } from '../stores/calibration.js'
import { useNavigation } from '../stores/navigation.js'
import { calibrationName } from '../services/calibration.js'
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
 * One calibration, the one the menu opened: a new one from views of a chessboard, over the one in use. Joining the
 * calibration channel turns board detection on in the unit, so only this page joins it, while mounted.
 */
export default function CalibrationPage() {
  const listen = useCalibration((state) => state.listen)
  const select = useCalibration((state) => state.select)
  const unavailable = useCalibration((state) => state.unavailable)
  const phase = useCalibration((state) => state.session?.phase ?? null)
  const title = useCalibration((state) => {
    const calibration = selectedCalibration(state)
    return calibration ? calibrationName(calibration) : 'Calibration'
  })
  const calibrationId = useNavigation((state) => state.calibrationId)
  const uncalibrated = useStatus((state) => state.snapshot?.calibrated === false)

  useEffect(() => listen(dashboardSocket), [listen])

  useEffect(() => {
    if (calibrationId != null) select(calibrationId)
  }, [calibrationId, select])

  return (
    <OvcsPageFrame title={title}>
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
          <Step phase={phase} />
          <InUse />
        </>
      )}
    </OvcsPageFrame>
  )
}
