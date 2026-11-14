import { OvcsStatus } from '@ovcs/ui/react'
import { HealthValue } from '../UnitStatus.jsx'
import Flow from './Flow.jsx'
import { SessionError } from './Errors.jsx'
import { selectedCalibration, useCalibration } from '../../stores/calibration.js'
import { downloadYaml } from '../../services/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { BUTTON, PRIMARY } from '../../styles.js'

// Under half a pixel is a good calibration; over two pixels it needs more samples or better board angles.
const rmsVerdict = (px) =>
  px < 0.5 ? { tone: 'ok', word: 'good' } : px > 2 ? { tone: 'error', word: 'poor' } : { tone: 'warn', word: 'fair' }

const pixels = (px) => (px == null ? '–' : `${formatNumber(px)} px`)

const capitalised = (name) => name.charAt(0).toUpperCase() + name.slice(1)

function Row({ label, solved, inUse }) {
  return (
    <tr className="border-t border-ovcs-border">
      <th scope="row" className="py-1 pr-6 font-medium">
        {label}
      </th>
      <td className="py-1 pr-6">{solved}</td>
      {inUse === undefined ? null : <td className="py-1 text-ovcs-muted">{inUse ?? ''}</td>}
    </tr>
  )
}

function RmsValue({ px }) {
  // An error the solve did not give is not judged.
  if (px == null) return '–'
  const { tone, word } = rmsVerdict(px)

  return (
    <OvcsStatus tone={tone} className="font-semibold">
      <HealthValue tone={tone}>{`${formatNumber(px, 2)} px, ${word}`}</HealthValue>
    </OvcsStatus>
  )
}

/** The solved calibration's reprojection errors, then a pair's baseline and the focal length beside the ones in use. */
function Figures() {
  const solution = useCalibration((state) => state.session?.result)
  const inUse = useCalibration(selectedCalibration)

  // Only a calibrated pair has figures to set beside the new ones.
  const used = (value) => (inUse?.kind === 'stereo' && inUse.source !== 'none' ? value : undefined)
  // A focal length is in pixels of its image: the one in use compares only at the solve's image size.
  const [camera] = inUse?.cameras ?? []
  const sameSize = solution != null && camera?.imageWidth === solution.imageWidth && camera?.imageHeight === solution.imageHeight

  return solution ? (
    <div className="overflow-x-auto">
      <table className="text-left text-sm tabular-nums">
        <thead className="text-xs text-ovcs-muted">
          <tr>
            <th className="pb-1 pr-4 font-medium">
              <span className="sr-only">figure</span>
            </th>
            <th className="pb-1 pr-6 font-medium">{`New, from ${solution.samples} views`}</th>
            {used(true) ? <th className="pb-1 font-medium">Used now</th> : null}
          </tr>
        </thead>
        <tbody>
          {solution.cameras.map((camera) => (
            <Row key={camera.name} label={`${capitalised(camera.name)} camera error (reprojection RMS)`} solved={<RmsValue px={camera.rmsPx} />} inUse={used(null)} />
          ))}
          {solution.stereoRmsPx == null ? null : (
            <>
              <Row label="Pair error (stereo reprojection RMS)" solved={<RmsValue px={solution.stereoRmsPx} />} inUse={used(null)} />
              <Row label="Distance between cameras (baseline)" solved={millimetres(solution.baselineM)} inUse={used(millimetres(inUse?.baselineM))} />
            </>
          )}
          <Row label="Focal length (fx)" solved={pixels(solution.fxPx)} inUse={used(sameSize ? pixels(inUse?.rectifiedFx) : null)} />
        </tbody>
      </table>
    </div>
  ) : null
}

/** The solved calibration; Apply has the unit take it, Download saves its YAMLs, Discard drops it. */
export function Solved() {
  const solution = useCalibration((state) => state.session?.result)
  const busy = useCalibration((state) => state.busy)
  const apply = useCalibration((state) => state.apply)
  const cancel = useCalibration((state) => state.cancel)

  const download = () => {
    for (const camera of solution.cameras) downloadYaml(camera.file, camera.yaml)
  }

  return (
    <Flow step={2}>
      <p className="max-w-prose text-sm text-ovcs-muted">
        The errors say how well the calibration fits the views kept: under 0.5 px is good, over 2 px needs more views or more varied ones.
      </p>
      <Figures />
      <SessionError />
      <div className="flex flex-wrap gap-2">
        <button type="button" disabled={busy} onClick={apply} className={PRIMARY}>
          Use this calibration
        </button>
        <button
          type="button"
          aria-label="Download the new calibration"
          disabled={!solution}
          onClick={download}
          className={BUTTON}
        >
          Download
        </button>
        <button type="button" disabled={busy} onClick={cancel} className={BUTTON}>
          Discard
        </button>
      </div>
    </Flow>
  )
}

/** The unit taking the solved calibration, which cannot be stopped. */
export function Applying() {
  return (
    <Flow step={2}>
      <Figures />
      <p role="status" className="text-sm">
        Applying… the unit is taking the calibration.
      </p>
    </Flow>
  )
}
