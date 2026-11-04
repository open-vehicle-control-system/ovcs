import { displayValue, isMultiline } from '../format.js'
import { useMetrics } from '../stores/metrics.js'

const CHECK = (
  <svg aria-hidden="true" viewBox="0 0 20 20" fill="currentColor" className="inline size-5 text-ovcs-ok-text">
    <path
      fillRule="evenodd"
      d="M16.7 5.3a1 1 0 0 1 0 1.4l-8 8a1 1 0 0 1-1.4 0l-4-4a1 1 0 1 1 1.4-1.4L8 12.58l7.3-7.3a1 1 0 0 1 1.4 0Z"
    />
  </svg>
)

const CROSS = (
  <svg aria-hidden="true" viewBox="0 0 20 20" fill="currentColor" className="inline size-5 text-ovcs-muted">
    <path d="M5.7 4.3a1 1 0 0 0-1.4 1.4L8.58 10l-4.3 4.3a1 1 0 1 0 1.42 1.4L10 11.42l4.3 4.3a1 1 0 0 0 1.4-1.42L11.42 10l4.3-4.3a1 1 0 0 0-1.42-1.4L10 8.58 5.7 4.3Z" />
  </svg>
)

/** A metric row's live value, once its module has published. */
export default function MetricValue({ row }) {
  const published = useMetrics((state) => state.data[row.module] !== undefined)
  const value = useMetrics((state) => state.data[row.module]?.[row.key])
  const publisherUnit = useMetrics((state) => state.units[row.module]?.[row.key])

  if (!published) return null
  if (typeof value === 'boolean') {
    return (
      <>
        {value ? CHECK : CROSS}
        <span className="sr-only">{value ? 'yes' : 'no'}</span>
      </>
    )
  }
  if (isMultiline(value)) {
    return <pre className="whitespace-pre-wrap break-words text-left font-mono text-xs">{value}</pre>
  }
  return <span className="tabular-nums">{displayValue(value, row, publisherUnit)}</span>
}
