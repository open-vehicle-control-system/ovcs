import Section from './Section.jsx'
import { poseFacts } from './pose.js'
import { selectedCalibration, useCalibration } from '../../stores/calibration.js'
import { downloadYaml } from '../../services/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { BUTTON, PRIMARY } from '../../styles.js'

const stamp = (iso) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso))

// Where the position the unit uses comes from, as the card's title, then what that means.
function poseStatement({ source, storedAt }) {
  if (source === 'stored')
    return {
      title: storedAt ? `Measured on this unit, ${stamp(storedAt)}` : 'Measured on this unit',
      detail: 'The unit uses the position measured on it, in place of the one shipped with the firmware.'
    }
  if (source === 'builtIn')
    return {
      title: 'Using the position shipped with the firmware',
      detail: 'The position was not measured on this unit.'
    }
  return {
    title: 'Not measured',
    detail: "The camera's detections and segmentation have no distance until its position is measured."
  }
}

// What the unit uses, as the card's title, then what that means.
function statement({ source, storedAt, kind }) {
  if (kind === 'pose') return poseStatement({ source, storedAt })
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

const PARAMETERS = [
  { label: 'Focal x (fx)', of: (camera) => camera.fx },
  { label: 'Focal y (fy)', of: (camera) => camera.fy },
  { label: 'Centre x (cx)', of: (camera) => camera.cx },
  { label: 'Centre y (cy)', of: (camera) => camera.cy }
]

const LABEL = 'py-1 pr-4 text-left text-xs font-normal text-ovcs-muted'

const fourDecimals = (value) => formatNumber(value, 4)

// The rotation, row by row, and the translation, from the left camera's rectified frame to the camera's.
function PoseParameters({ pose }) {
  const rows = pose ? [0, 1, 2].map((row) => pose.rotation.slice(row * 3, row * 3 + 3)) : []

  return (
    <div className="flex min-w-0 flex-wrap gap-x-8 gap-y-3">
      <table className="text-right font-mono text-sm tabular-nums">
        <caption className="pb-1 text-left font-sans text-xs text-ovcs-muted">Rotation, from the left camera to this one</caption>
        <tbody>
          {rows.map((values, row) => (
            <tr key={row}>
              {values.map((value, column) => (
                <td key={column} className="py-0.5 pr-4">
                  {fourDecimals(value)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <table className="text-right text-sm tabular-nums">
        <caption className="pb-1 text-left text-xs text-ovcs-muted">Translation, in mm</caption>
        <thead className="text-xs text-ovcs-muted">
          <tr>
            {['x', 'y', 'z'].map((axis) => (
              <th key={axis} className="pb-1 pr-4 font-medium">
                {axis}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          <tr>
            {(pose?.translation ?? [null, null, null]).map((metres, axis) => (
              <td key={axis} className="py-0.5 pr-4">
                {metres == null ? '–' : formatNumber(metres * 1000)}
              </td>
            ))}
          </tr>
        </tbody>
      </table>
    </div>
  )
}

// A column per camera; the distortion coefficients one per line.
function Parameters({ cameras }) {
  return (
    <table className="w-full min-w-0 text-sm tabular-nums">
      <caption className="pb-1 text-left text-xs text-ovcs-muted">Camera parameters, in pixels</caption>
      <thead className="text-xs text-ovcs-muted">
        <tr>
          <th scope="col" className="pb-1 pr-4 text-left font-medium">
            Camera
          </th>
          {cameras.map((camera) => (
            <th key={camera.name} scope="col" className="pb-1 pr-4 text-right font-medium capitalize last:pr-0">
              {camera.name}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {PARAMETERS.map(({ label, of }) => (
          <tr key={label} className="border-t border-ovcs-border">
            <th scope="row" className={LABEL}>
              {label}
            </th>
            {cameras.map((camera) => (
              <td key={camera.name} className="py-1 pr-4 text-right last:pr-0">
                {formatNumber(of(camera))}
              </td>
            ))}
          </tr>
        ))}
        <tr className="border-t border-ovcs-border">
          <th scope="row" className={`${LABEL} align-top`}>
            Distortion (k1, k2, p1, p2, k3)
          </th>
          {cameras.map((camera) => (
            <td key={camera.name} className="py-1 pr-4 text-right align-top font-mono text-xs last:pr-0">
              {camera.distortion
                ? camera.distortion.map((coefficient, index) => (
                    <span key={index} className="block">
                      {fourDecimals(coefficient)}
                    </span>
                  ))
                : '–'}
            </td>
          ))}
        </tr>
      </tbody>
    </table>
  )
}

/**
 * The calibration the unit uses: where it comes from in plain words, the figures to check, and under them each
 * camera's parameters, or for a camera's position its rotation and translation; why a file gives no calibration, when
 * one does not. `onCalibrate`, when given, opens the steps that make a new one, from the button `calibrateRef` then
 * holds.
 */
export default function InUse({ onCalibrate, calibrateRef }) {
  const inUse = useCalibration(selectedCalibration)

  if (!inUse)
    return (
      <Section title="Calibration">
        <p className="text-sm text-ovcs-muted">Waiting for the vision unit…</p>
      </Section>
    )

  const { title, detail } = statement(inUse)
  const pose = inUse.kind === 'pose'

  const download = () => {
    if (pose) downloadYaml(inUse.pose.file, inUse.pose.yaml)
    else for (const camera of inUse.cameras) downloadYaml(camera.file, camera.yaml)
  }

  const downloadable = pose ? inUse.pose?.yaml : inUse.cameras.every((camera) => camera.yaml)

  const actions = (
    <div className="flex flex-wrap gap-2">
      {downloadable ? (
        <button
          type="button"
          aria-label={pose ? 'Download the position the unit uses' : 'Download the calibration the unit uses'}
          onClick={download}
          className={BUTTON}
        >
          Download
        </button>
      ) : null}
      {onCalibrate ? (
        <button ref={calibrateRef} type="button" onClick={onCalibrate} className={PRIMARY}>
          {inUse.source === 'none' ? 'Calibrate' : 'Calibrate again'}
        </button>
      ) : null}
    </div>
  )

  return (
    <Section title={title} tone={inUse.source === 'none' ? 'warn' : undefined} actions={actions}>
      <p className="text-sm text-ovcs-muted">{detail}</p>
      {inUse.error ? (
        <p role="alert" className="ovcs-status ovcs-status--error break-words text-sm text-ovcs-error-text">
          {inUse.error}
        </p>
      ) : null}
      <div className="flex flex-col gap-4">
        <dl className={`grid gap-x-4 gap-y-2 tabular-nums ${pose ? 'grid-cols-1' : 'grid-cols-2'}`}>
          {(pose ? poseFacts(inUse.pose) : facts(inUse)).map(({ label, value }) => (
            <div key={label} className="flex min-w-0 flex-col">
              <dt className="text-xs text-ovcs-muted">{label}</dt>
              <dd className="font-semibold">{value}</dd>
            </div>
          ))}
        </dl>
        {pose ? <PoseParameters pose={inUse.pose} /> : <Parameters cameras={inUse.cameras} />}
      </div>
    </Section>
  )
}
