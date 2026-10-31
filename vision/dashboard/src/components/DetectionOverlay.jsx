/**
 * The detected objects over a preview: each outline, given as fractions of the image, and a label with its
 * distance. The view box is the image's own size, fitted like the image, so the boxes stay on it at any size.
 */
export default function DetectionOverlay({ detections, width, height }) {
  const fontSize = Math.max(10, height / 20)

  return (
    <svg
      data-detections
      aria-hidden="true"
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
              x={left * width + 3}
              y={Math.max(top * height - 4, fontSize)}
              fontSize={fontSize}
              fill="white"
              stroke="black"
              strokeWidth={fontSize / 5}
              paintOrder="stroke"
            >
              {`${detection.label} ${detection.distance_m.toFixed(1)} m`}
            </text>
          </g>
        )
      })}
    </svg>
  )
}

const round = (value) => Math.round(value * 10) / 10
