import { OvcsStatus } from '@ovcs/ui/react'
import { HealthValue } from '../UnitStatus.jsx'
import Section from './Section.jsx'
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

/** The solved calibration's reprojection errors, then a pair's baseline and the focal length beside the ones in use. */
function Figures() {
  const solution = useCalibration((state) => state.session?.result)
  const inUse = useCalibration(selectedCalibration)

  return solution ? (
    <div className="overflow-x-auto">
      <table className="text-left text-sm tabular-nums">
        <thead className="text-xs text-ovcs-muted">
          <tr>
            <th className="pb-1 pr-4 font-medium">
              <span className="sr-only">figure</span>
            </th>
            <th className="pb-1 pr-4 font-medium">{`new, from ${solution.samples} views`}</th>
            <th className="pb-1 font-medium">current</th>
          </tr>
        </thead>
        <tbody>
          {solution.cameras.map((camera) => (
            <Row key={camera.name} label={`${capitalised(camera.name)} camera error`} solved={<RmsValue px={camera.rmsPx} />} />
          ))}
          {solution.stereoRmsPx == null ? null : (
            <>
              <Row label="Pair error" solved={<RmsValue px={solution.stereoRmsPx} />} />
              <Row label="Distance between cameras" solved={millimetres(solution.baselineM)} inUse={millimetres(inUse?.baselineM)} />
            </>
          )}
          <Row label="Focal length" solved={pixels(solution.fxPx)} inUse={pixels(inUse?.rectifiedFx)} />
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
    <Section title="New calibration">
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
    </Section>
  )
}

/** The unit taking the solved calibration, which cannot be stopped. */
export function Applying() {
  return (
    <Section title="New calibration">
      <Figures />
      <p role="status" className="text-sm">
        Applying… the unit is taking the calibration.
      </p>
    </Section>
  )
}
