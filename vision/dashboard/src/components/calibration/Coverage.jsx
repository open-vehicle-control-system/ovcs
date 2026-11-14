import Gauge from '../Gauge.jsx'
import { useCalibration } from '../../stores/calibration.js'

const AXES = [
  { axis: 'x', label: 'Left to right', term: 'X' },
  { axis: 'y', label: 'Top to bottom', term: 'Y' },
  { axis: 'size', label: 'Near to far', term: 'size' },
  { axis: 'skew', label: 'Tilted', term: 'skew' }
]

// Each axis follows its own percentage, which changes far less often than the session.
function Axis({ axis, label, term }) {
  const percent = useCalibration((state) => Math.round((state.session?.progress?.[axis] ?? 0) * 100))
  const covered = percent >= 100

  return (
    <li
      role="progressbar"
      aria-label={`${label} (${term})`}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={percent}
      className="flex flex-col gap-0.5"
    >
      <div className="flex items-center justify-between gap-2 text-xs">
        <span className="font-medium text-ovcs-muted">
          {label} <span className="font-normal">({term})</span>
        </span>
        <span className={`font-semibold tabular-nums ${covered ? 'text-ovcs-ok' : ''}`}>{percent} %</span>
      </div>
      <Gauge position={percent} zone={[100, 100]} tone={covered ? 'ok' : 'error'} />
    </li>
  )
}

function SampleCount() {
  const samples = useCalibration((state) => state.session?.samples ?? 0)

  return (
    <li className="flex flex-col gap-0.5 text-xs">
      <span className="font-medium text-ovcs-muted">Views kept (samples)</span>
      <span className="text-base font-semibold tabular-nums">{samples}</span>
    </li>
  )
}

/** How far the views kept cover where the board can be: across, up and down, near and far, and tilted, each from 0 to 100 %, then how many views there are. */
export default function Coverage() {
  return (
    <ul role="group" aria-label="Board positions covered" className="flex min-w-0 flex-col gap-3">
      {AXES.map(({ axis, label, term }) => (
        <Axis key={axis} axis={axis} label={label} term={term} />
      ))}
      <SampleCount />
    </ul>
  )
}
