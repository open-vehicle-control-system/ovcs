import { createContext, use, useId } from 'react'
import { OvcsCard } from '@ovcs/ui/react'
import { selectedCalibration, useCalibration } from '../../stores/calibration.js'
import { BUTTON } from '../../styles.js'

/** Closes the dialog the flow is in, provided while it can be closed without ending a session. */
export const FlowClose = createContext(null)

const steps = (cameras) => ['Describe the board', cameras > 1 ? 'Show it to the cameras' : 'Show it to the camera', 'Check the result']

function Step({ number, label, state }) {
  const tone = state === 'current' ? 'border-ovcs-accent text-ovcs-text' : state === 'done' ? 'border-ovcs-ok text-ovcs-ok' : 'border-ovcs-border'

  return (
    <li aria-current={state === 'current' ? 'step' : undefined} className={`flex items-center gap-2 ${state === 'current' ? 'font-semibold' : 'text-ovcs-muted'}`}>
      <span aria-hidden="true" className={`flex size-6 shrink-0 items-center justify-center rounded-full border text-xs tabular-nums ${tone}`}>
        {state === 'done' ? '✓' : number}
      </span>
      {label}
    </li>
  )
}

/** The card that makes a calibration, with the three steps and the one it is at, `step` counted from 0, and Close where `FlowClose` gives one. */
export default function Flow({ step, children }) {
  const headingId = useId()
  const close = use(FlowClose)
  const calibrated = useCalibration((state) => (selectedCalibration(state)?.source ?? 'none') !== 'none')

  const cameras = useCalibration((state) => selectedCalibration(state)?.cameras.length ?? 1)

  return (
    <OvcsCard as="section" aria-labelledby={headingId} className="flex min-w-0 flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-x-8 gap-y-2">
        <h3 id={headingId} className="mr-auto font-semibold">
          {calibrated ? 'Calibrate again' : 'Calibrate'}
        </h3>
        <ol aria-label="Steps" className="flex flex-wrap gap-x-6 gap-y-1 text-sm">
          {steps(cameras).map((label, index) => (
            <Step key={label} number={index + 1} label={label} state={index === step ? 'current' : index < step ? 'done' : 'pending'} />
          ))}
        </ol>
        {close ? (
          <button type="button" onClick={close} className={BUTTON}>
            Close
          </button>
        ) : null}
      </div>
      {children}
    </OvcsCard>
  )
}
