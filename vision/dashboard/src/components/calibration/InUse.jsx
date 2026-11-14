import Section from './Section.jsx'
import { selectedCalibration, useCalibration } from '../../stores/calibration.js'
import { downloadYaml } from '../../services/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { BUTTON, PRIMARY } from '../../styles.js'

const CONFIRM_RESET = "Go back to the firmware's calibration? The calibration made on this unit is deleted."

const stamp = (iso) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso))

// What the unit uses, as the card's title, then what that means.
function statement({ source, storedAt, kind }) {
  if (source === 'stored')
    return {
      title: storedAt ? `Calibrated on this unit, ${stamp(storedAt)}` : 'Calibrated on this unit',
      detail: 'The unit uses the calibration made on it, in place of the one shipped with the firmware.'
    }
  if (source === 'builtIn')
    return {
      title: 'Using the calibration shipped with the firmware',
      detail: 'No calibration was made on this unit.'
    }
  return {
    title: 'Not calibrated',
    detail: kind === 'stereo' ? 'Depth stays off until a calibration is made.' : 'The camera is used without a calibration.'
  }
}

const corrected = (cameras) => cameras.some((camera) => camera.distortion?.some((coefficient) => coefficient !== 0))

const sized = (camera) => (camera?.imageWidth == null ? '–' : `${camera.imageWidth} × ${camera.imageHeight} px`)

const distortion = (cameras) => (cameras[0]?.distortion == null ? '–' : corrected(cameras) ? 'Corrected' : 'Not corrected')

// The figures a person can check against the hardware, in the same places for every calibration: the baseline, which
// only a pair has, comes last.
function facts(inUse) {
  const [first] = inUse.cameras
  const focal = inUse.rectifiedFx ?? first?.fx
  return [
    { label: 'Image size', value: sized(first) },
    { label: 'Focal length (fx)', value: focal == null ? '–' : `${formatNumber(focal)} px` },
    { label: 'Lens distortion', value: distortion(inUse.cameras) },
    ...(inUse.kind === 'stereo' ? [{ label: 'Distance between cameras (baseline)', value: millimetres(inUse.baselineM) }] : [])
  ]
}

const COLUMNS = ['Focal x (fx)', 'Focal y (fy)', 'Centre x (cx)', 'Centre y (cy)']

function CameraRow({ camera }) {
  return (
    <tr className="border-t border-ovcs-border">
      <th scope="row" className="py-1 pr-4 font-medium capitalize">
        {camera.name}
      </th>
      {[camera.fx, camera.fy, camera.cx, camera.cy].map((value, index) => (
        <td key={COLUMNS[index]} className="py-1 pr-4 text-right">
          {formatNumber(value)}
        </td>
      ))}
      <td className="py-1 font-mono text-xs">
        {camera.distortion ? camera.distortion.map((coefficient) => formatNumber(coefficient, 4)).join(', ') : '–'}
      </td>
    </tr>
  )
}

function Parameters({ cameras }) {
  return (
    <div className="min-w-0 overflow-x-auto lg:border-l lg:border-ovcs-border lg:pl-8">
      <table className="text-left text-sm tabular-nums">
        <caption className="pb-1 text-left text-xs text-ovcs-muted">Camera parameters, in pixels</caption>
        <thead className="text-xs text-ovcs-muted">
          <tr>
            <th className="pb-1 pr-4 font-medium">Camera</th>
            {COLUMNS.map((column) => (
              <th key={column} className="pb-1 pr-4 text-right font-medium">
                {column}
              </th>
            ))}
            <th className="pb-1 font-medium">Distortion (k1, k2, p1, p2, k3)</th>
          </tr>
        </thead>
        <tbody>
          {cameras.map((camera) => (
            <CameraRow key={camera.name} camera={camera} />
          ))}
        </tbody>
      </table>
    </div>
  )
}

/** The calibration the unit uses: where it comes from in plain words, the figures to check, and beside them each camera's parameters; `onCalibrate`, when given, opens the steps that make a new one. */
export default function InUse({ onCalibrate }) {
  const inUse = useCalibration(selectedCalibration)
  const busy = useCalibration((state) => state.busy)
  const applying = useCalibration((state) => state.session?.phase === 'applying')
  const reset = useCalibration((state) => state.reset)

  if (!inUse)
    return (
      <Section title="Calibration">
        <p className="text-sm text-ovcs-muted">Waiting for the vision unit…</p>
      </Section>
    )

  const { title, detail } = statement(inUse)

  const download = () => {
    for (const camera of inUse.cameras) downloadYaml(camera.file, camera.yaml)
  }

  const returnToBuiltIn = () => {
    if (window.confirm(CONFIRM_RESET)) reset()
  }

  const actions = (
    <div className="flex flex-wrap gap-2">
      {inUse.cameras.every((camera) => camera.yaml) ? (
        <button type="button" aria-label="Download the calibration the unit uses" onClick={download} className={BUTTON}>
          Download
        </button>
      ) : null}
      {inUse.canReset ? (
        <button type="button" disabled={busy || applying} onClick={returnToBuiltIn} className={BUTTON}>
          Go back to the firmware's calibration
        </button>
      ) : null}
      {onCalibrate ? (
        <button type="button" onClick={onCalibrate} className={PRIMARY}>
          {inUse.source === 'none' ? 'Calibrate' : 'Calibrate again'}
        </button>
      ) : null}
    </div>
  )

  return (
    <Section title={title} tone={inUse.source === 'none' ? 'warn' : undefined} actions={actions}>
      <p className="text-sm text-ovcs-muted">{detail}</p>
      <div className="flex min-h-[6.5rem] flex-wrap items-start gap-x-8 gap-y-3">
        <dl className="grid grid-cols-[9rem_15rem] gap-x-8 gap-y-2 tabular-nums">
          {facts(inUse).map(({ label, value }) => (
            <div key={label} className="flex flex-col">
              <dt className="text-xs text-ovcs-muted">{label}</dt>
              <dd className="font-semibold">{value}</dd>
            </div>
          ))}
        </dl>
        <Parameters cameras={inUse.cameras} />
      </div>
    </Section>
  )
}
