import Section from './Section.jsx'
import { BASELINE, CAPTION, Figures, INDENTED_LABEL, LABEL, RULE, VALUE } from './Figures.jsx'
import { downloadFiles, yamlFiles } from './files.js'
import { poseFacts } from './pose.js'
import { selectedCalibration, selectedId, useCalibration } from '../../stores/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { BUTTON, PRIMARY } from '../../styles.js'

const stamp = (iso) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso))

// Where the position the unit uses comes from, as the card's title, then what that means.
function poseStatement({ source }) {
  if (source === 'stored')
    return {
      title: 'Measured on this unit',
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
function statement({ source, kind }) {
  if (kind === 'pose') return poseStatement({ source })
  if (source === 'stored')
    return {
      title: 'Calibrated on this unit',
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

// Which stored calibration is in use: the one kept by its name and when it was made, else when it was stored.
function storedName({ source, storedAt }, inForce) {
  if (source !== 'stored') return null
  if (inForce) return `${inForce.name} · made ${stamp(inForce.createdAt)}`
  return storedAt ? stamp(storedAt) : null
}

const corrected = (cameras) => cameras.some((camera) => camera.distortion?.some((coefficient) => coefficient !== 0))

const sized = (camera) => (camera?.imageWidth == null ? '–' : `${camera.imageWidth} × ${camera.imageHeight} px`)

const distortion = (cameras) => (cameras[0]?.distortion == null ? '–' : corrected(cameras) ? 'Corrected' : 'Not corrected')

// The figures a person can check against the hardware; the baseline, which only a pair has, comes last.
function facts(inUse) {
  const [first] = inUse.cameras
  return [
    { label: 'Image size', value: sized(first) },
    { label: 'Lens distortion', value: distortion(inUse.cameras) },
    ...(inUse.kind === 'stereo' ? [{ label: BASELINE, value: millimetres(inUse.baselineM) }] : [])
  ]
}

const poseFigures = (pose) => poseFacts(pose).map(({ label, value, parts }) => ({ label, value: parts ?? value }))

const PARAMETERS = [
  { label: 'Focal x (fx)', of: (camera) => camera.fx },
  { label: 'Focal y (fy)', of: (camera) => camera.fy },
  { label: 'Centre x (cx)', of: (camera) => camera.cx },
  { label: 'Centre y (cy)', of: (camera) => camera.cy }
]

const COEFFICIENTS = ['k1', 'k2', 'p1', 'p2', 'k3']

const FIRST_RULED = `${RULE} first:border-t-0`

const fourDecimals = (value) => formatNumber(value, 4)

const capitalised = (name) => name.charAt(0).toUpperCase() + name.slice(1)

// The rotation, row by row, and the translation, from the left camera's rectified frame to the camera's.
function PoseParameters({ pose }) {
  const rows = [0, 1, 2].map((row) => pose.rotation.slice(row * 3, row * 3 + 3))

  return (
    <div className="flex flex-col gap-4">
      <table className="w-full table-fixed text-sm tabular-nums">
        <caption className={CAPTION}>Rotation, from the left camera to this one</caption>
        <tbody>
          {rows.map((values, row) => (
            <tr key={row} className={FIRST_RULED}>
              {values.map((value, column) => (
                <td key={column} className={VALUE}>
                  {fourDecimals(value)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <table className="w-full text-sm tabular-nums">
        <caption className={CAPTION}>Translation, in mm</caption>
        <tbody>
          {['x', 'y', 'z'].map((axis, index) => (
            <tr key={axis} className={FIRST_RULED}>
              <th scope="row" className={`${LABEL} w-full`}>
                {axis}
              </th>
              <td className={VALUE}>{formatNumber(pose.translation[index] * 1000)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

// A row per parameter, a column per camera headed by its name for a pair; the distortion a coefficient a row.
function Parameters({ cameras }) {
  const pair = cameras.length > 1

  return (
    <table className="w-full text-sm tabular-nums">
      <caption className={CAPTION}>Camera parameters, in pixels</caption>
      {pair ? (
        <thead>
          <tr>
            <td />
            {cameras.map((camera) => (
              <th key={camera.name} scope="col" className="pb-1 pl-4 pr-0 text-right text-xs font-medium text-ovcs-muted">
                {capitalised(camera.name)}
              </th>
            ))}
          </tr>
        </thead>
      ) : null}
      <tbody>
        {PARAMETERS.map(({ label, of }) => (
          <tr key={label} className={FIRST_RULED}>
            <th scope="row" className={`${LABEL} w-full`}>
              {label}
            </th>
            {cameras.map((camera) => (
              <td key={camera.name} className={VALUE}>
                {formatNumber(of(camera))}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
      <tbody>
        <tr className={RULE}>
          <th scope="rowgroup" colSpan={cameras.length + 1} className="px-0 pb-0.5 pt-2 text-left text-xs font-medium">
            Distortion
          </th>
        </tr>
        {COEFFICIENTS.map((label, index) => (
          <tr key={label} className={RULE}>
            <th scope="row" className={INDENTED_LABEL}>
              {label}
            </th>
            {cameras.map((camera) => (
              <td key={camera.name} className={VALUE}>
                {camera.distortion ? fourDecimals(camera.distortion[index]) : '–'}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  )
}

/**
 * The calibration the unit uses: where it comes from in plain words, which one it is, the figures to check, and under
 * them each camera's parameters, or for a measured position its rotation and translation; why a file gives no
 * calibration, when one does not. Its files download from the calibration kept in use, or from here when none is.
 * `onCalibrate`, when given, opens the steps that make a new one, from the button `calibrateRef` then holds.
 */
export default function InUse({ onCalibrate, calibrateRef }) {
  const inUse = useCalibration(selectedCalibration)
  const inForce = useCalibration((state) => state.saved[selectedId(state)]?.find((kept) => kept.inForce) ?? null)

  if (!inUse)
    return (
      <Section title="Calibration">
        <p className="text-sm text-ovcs-muted">Waiting for the vision unit…</p>
      </Section>
    )

  const { title, detail } = statement(inUse)
  const pose = inUse.kind === 'pose'
  const files = yamlFiles(inUse, pose)
  const downloadedFromKept = inForce != null && yamlFiles(inForce, inForce.pose != null).length > 0

  const actions = (
    <div className="flex flex-wrap gap-2">
      {files.length > 0 && !downloadedFromKept ? (
        <button
          type="button"
          aria-label={pose ? 'Download the position the unit uses' : 'Download the calibration the unit uses'}
          onClick={() => downloadFiles(files)}
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
    <Section
      title={title}
      tone={inUse.source === 'none' ? 'warn' : undefined}
      subtitle={storedName(inUse, inForce)}
      actions={actions}
    >
      <p className="text-sm text-ovcs-muted">{detail}</p>
      {inUse.error ? (
        <p role="alert" className="ovcs-status ovcs-status--error break-words text-sm text-ovcs-error-text">
          {inUse.error}
        </p>
      ) : null}
      <div className="flex flex-col gap-4">
        <Figures figures={pose ? poseFigures(inUse.pose) : facts(inUse)} />
        {pose ? inUse.pose && <PoseParameters pose={inUse.pose} /> : <Parameters cameras={inUse.cameras} />}
      </div>
    </Section>
  )
}
