import Gauge from '../Gauge.jsx'
import { useCalibration } from '../../stores/calibration.js'

const AXES = [
  { axis: 'x', label: 'X' },
  { axis: 'y', label: 'Y' },
  { axis: 'size', label: 'Size' },
  { axis: 'skew', label: 'Skew' }
]

// Each axis follows its own percentage, which changes far less often than the session.
function Axis({ axis, label }) {
  const percent = useCalibration((state) => Math.round((state.session?.progress?.[axis] ?? 0) * 100))
  const covered = percent >= 100

  return (
    <li
      role="progressbar"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={percent}
      className="flex flex-col gap-0.5"
    >
      <div className="flex items-center justify-between gap-2 text-xs">
        <span className="font-medium text-ovcs-muted">{label}</span>
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
      <span className="font-medium text-ovcs-muted">Samples</span>
      <span className="text-base font-semibold tabular-nums">{samples}</span>
    </li>
  )
}

/** How far the samples cover the board's position, size and skew, each from 0 to 100 %, and how many there are. */
export default function Coverage() {
  return (
    <ul role="group" aria-label="Coverage" className="grid min-w-0 flex-1 grid-cols-2 gap-x-6 gap-y-2 sm:grid-cols-5">
      {AXES.map(({ axis, label }) => (
        <Axis key={axis} axis={axis} label={label} />
      ))}
      <SampleCount />
    </ul>
  )
}
