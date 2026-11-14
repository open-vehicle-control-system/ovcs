import { useFrameSize } from '../Preview.jsx'
import { useHeld } from './held.js'
import { useCalibration } from '../../stores/calibration.js'

const TONES = {
  sample: { className: 'text-ovcs-ok', label: 'Board found, kept as a sample' },
  detected: { className: 'text-ovcs-accent', label: 'Board found' }
}

const round = (value) => Math.round(value * 10) / 10

/**
 * The board corners the session's latest detection found on one camera's frame, given as fractions of the image: a
 * circle each, joined in their order, row by row, as OpenCV draws them. Coloured once the detection became a sample, and kept through a detection that misses the board. The
 * view box is the frame's own size, fitted like the frame, so the corners stay on it at any size.
 */
export default function CornerOverlay({ camera }) {
  const { width, height } = useFrameSize()
  const corners = useHeld(
    useCalibration((state) => state.session?.detection?.views?.find((view) => view.camera === camera)?.points ?? null)
  )
  const kind = useCalibration((state) => (state.session?.detection?.sample ? 'sample' : 'detected'))

  if (!corners) return null

  const tone = TONES[kind]
  const points = corners.map(([x, y]) => [round(x * width), round(y * height)])
  const stroke = Math.max(1, width / 400)

  return (
    <svg
      data-corners
      role="img"
      aria-label={tone.label}
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="xMidYMid meet"
      className={`pointer-events-none absolute inset-0 h-full w-full ${tone.className}`}
    >
      <polyline points={points.map(([x, y]) => `${x},${y}`).join(' ')} fill="none" stroke="currentColor" strokeWidth={stroke} />
      {points.map(([x, y], index) => (
        <circle key={index} cx={x} cy={y} r={Math.max(2, width / 160)} fill="none" stroke="currentColor" strokeWidth={stroke} />
      ))}
    </svg>
  )
}
