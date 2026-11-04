import { OvcsStatus } from '@ovcs/ui/react'
import { HealthValue } from '../UnitStatus.jsx'
import Section from './Section.jsx'
import { SessionError } from './Errors.jsx'
import { useCalibration } from '../../stores/calibration.js'
import { downloadYaml } from '../../services/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { BUTTON, PRIMARY } from '../../styles.js'

// Under half a pixel is a good calibration; over two pixels it needs more samples or better board angles.
const rmsVerdict = (px) =>
  px < 0.5 ? { tone: 'ok', word: 'good' } : px > 2 ? { tone: 'error', word: 'poor' } : { tone: 'warn', word: 'fair' }

const pixels = (px) => (px == null ? '–' : `${formatNumber(px)} px`)

const RMS = [
  { key: 'leftRmsPx', label: 'Left RMS' },
  { key: 'rightRmsPx', label: 'Right RMS' },
  { key: 'stereoRmsPx', label: 'Stereo RMS' }
]

function Row({ label, solved, inUse }) {
  return (
    <tr className="border-t border-ovcs-border">
      <th scope="row" className="py-1 pr-4 font-medium">
        {label}
      </th>
      <td className="py-1 pr-4">{solved}</td>
      <td className="py-1 text-ovcs-muted">{inUse}</td>
    </tr>
  )
}

function RmsValue({ px }) {
  const { tone, word } = rmsVerdict(px)

  return (
    <OvcsStatus tone={tone} className="font-semibold">
      <HealthValue tone={tone}>{`${formatNumber(px, 2)} px, ${word}`}</HealthValue>
    </OvcsStatus>
  )
}

/** The solved calibration's reprojection errors, then its baseline and rectified focal length beside the ones in use. */
function Figures() {
  const solution = useCalibration((state) => state.session?.result)
  const inUse = useCalibration((state) => state.inUse)

  return solution ? (
    <div className="overflow-x-auto">
      <table className="text-left text-sm tabular-nums">
        <thead className="text-xs text-ovcs-muted">
          <tr>
            <th className="pb-1 pr-4 font-medium">
              <span className="sr-only">figure</span>
            </th>
            <th className="pb-1 pr-4 font-medium">{`new, ${solution.samples} samples`}</th>
            <th className="pb-1 font-medium">in use</th>
          </tr>
        </thead>
        <tbody>
          {RMS.map(({ key, label }) => (
            <Row key={key} label={label} solved={<RmsValue px={solution[key]} />} />
          ))}
          <Row label="Baseline" solved={millimetres(solution.baselineM)} inUse={millimetres(inUse?.baselineM)} />
          <Row label="focal length (rectified)" solved={pixels(solution.fxPx)} inUse={pixels(inUse?.rectifiedFx)} />
        </tbody>
      </table>
    </div>
  ) : null
}

/** The solved calibration; Apply has the unit take it, Download saves its YAMLs, Discard drops it. */
export function Solved() {
  const solution = useCalibration((state) => state.session?.result)
  const prefix = useCalibration((state) => state.inUse?.prefix)
  const busy = useCalibration((state) => state.busy)
  const apply = useCalibration((state) => state.apply)
  const cancel = useCalibration((state) => state.cancel)

  const download = () => {
    downloadYaml(`${prefix}_left.yaml`, solution.left.yaml)
    downloadYaml(`${prefix}_right.yaml`, solution.right.yaml)
  }

  return (
    <Section title="Result">
      <Figures />
      <SessionError />
      <div className="flex flex-wrap gap-2">
        <button type="button" disabled={busy} onClick={apply} className={PRIMARY}>
          Apply
        </button>
        <button
          type="button"
          aria-label="Download the solved calibration"
          disabled={!prefix || !solution}
          onClick={download}
          className={BUTTON}
        >
          Download
        </button>
        <button type="button" disabled={busy} onClick={cancel} className={BUTTON}>
          Discard
        </button>
      </div>
    </Section>
  )
}

/** The unit taking the solved calibration, which cannot be stopped. */
export function Applying() {
  return (
    <Section title="Result">
      <Figures />
      <p role="status" className="text-sm">
        Applying… the unit is taking the calibration.
      </p>
    </Section>
  )
}
