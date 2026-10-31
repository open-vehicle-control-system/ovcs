import { useFrameSize } from './Preview.jsx'
import { formatNumber } from '../status.js'

const distance = (detection) => `${formatNumber(detection.distance_m)}\u00a0m`

/**
 * The detected objects over a preview's frame: each outline, given as fractions of the image, and a label with its
 * distance. The view box is the frame's own size, fitted like the frame, so the boxes stay on it at any size.
 */
export default function DetectionOverlay({ detections }) {
  const { width, height } = useFrameSize()
  const fontSize = Math.max(10, height / 20)
  // What it draws, said in words; with nothing drawn it is hidden.
  const description =
    detections.length > 0
      ? `Detected: ${detections.map((detection) => `${detection.label} at ${distance(detection)}`).join(', ')}`
      : undefined

  return (
    <svg
      data-detections
      role={description ? 'img' : undefined}
      aria-label={description}
      aria-hidden={description ? undefined : 'true'}
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="xMidYMid meet"
      className="pointer-events-none absolute inset-0 h-full w-full text-ovcs-accent"
    >
      {detections.map((detection, index) => {
        const points = detection.outline.map(([x, y]) => `${round(x * width)},${round(y * height)}`).join(' ')
        const [left, top] = detection.outline[0] ?? [0, 0]
        return (
          <g key={index}>
            <polygon points={points} fill="none" stroke="currentColor" strokeWidth={Math.max(1.5, width / 300)} />
            <text
              x={round(left * width + 3)}
              y={round(Math.max(top * height - 4, fontSize))}
              fontSize={fontSize}
              fill="white"
              stroke="black"
              strokeWidth={fontSize / 5}
              paintOrder="stroke"
            >
              {`${detection.label} ${distance(detection)}`}
            </text>
          </g>
        )
      })}
    </svg>
  )
}

const round = (value) => Math.round(value * 10) / 10
