import { useCalibration } from '../../stores/calibration.js'

const AXES = [
  { axis: 'x', label: 'X' },
  { axis: 'y', label: 'Y' },
  { axis: 'size', label: 'Size' },
  { axis: 'skew', label: 'Skew' }
]

// Each bar follows its own percentage, which changes far less often than the session.
function Bar({ axis, label }) {
  const percent = useCalibration((state) => Math.round((state.session?.progress?.[axis] ?? 0) * 100))

  return (
    <div className="flex items-center gap-2 text-sm">
      <span className="w-10 text-ovcs-muted">{label}</span>
      <div
        role="progressbar"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={percent}
        className="h-2 flex-1 overflow-hidden rounded-sm bg-ovcs-border"
      >
        <div className={`h-full ${percent >= 100 ? 'bg-ovcs-ok' : 'bg-ovcs-accent'}`} style={{ width: `${percent}%` }} />
      </div>
      <span className="w-12 text-right tabular-nums">{percent} %</span>
    </div>
  )
}

function SampleCount() {
  const samples = useCalibration((state) => state.session?.samples ?? 0)

  return (
    <p className="flex gap-2 text-sm">
      <span className="text-ovcs-muted">Samples</span>
      <span className="font-semibold tabular-nums">{samples}</span>
    </p>
  )
}

/** How far the samples cover the board's position, size and skew, each from 0 to 100 %, and how many there are. */
export default function Coverage() {
  return (
    <div role="group" aria-label="Coverage" className="flex flex-col gap-1.5">
      {AXES.map(({ axis, label }) => (
        <Bar key={axis} axis={axis} label={label} />
      ))}
      <SampleCount />
    </div>
  )
}
