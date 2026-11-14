/**
 * The one look of every figure on the calibration panel: its label on the left, its value on the right, a rule
 * between rows. `Figures` lays out a list of them; tables take the same classes.
 */
const LABEL_TEXT = 'py-1.5 pr-3 text-left align-baseline text-xs font-normal text-ovcs-muted'
export const LABEL = `${LABEL_TEXT} pl-0`
export const INDENTED_LABEL = `${LABEL_TEXT} pl-3`
export const VALUE = 'whitespace-nowrap py-1.5 pl-4 pr-0 text-right align-baseline text-sm tabular-nums'
export const RULE = 'border-t border-ovcs-border'
export const CAPTION = 'pb-1 text-left text-sm font-medium'

/** The label of a pair's baseline, which says what it is to a screen reader. */
export const BASELINE = (
  <>
    Baseline<span className="sr-only"> (distance between the cameras)</span>
  </>
)

/** A value of several parts, one a line. */
function Lines({ value }) {
  if (!Array.isArray(value)) return value
  return value.map((part, index) => (
    <span key={index} className="block">
      {part}
    </span>
  ))
}

/** Figures, each `{ label, value }`, as a list. */
export function Figures({ figures }) {
  return (
    <dl className="flex flex-col divide-y divide-ovcs-border">
      {figures.map(({ label, value }, index) => (
        <div key={index} className="flex items-baseline justify-between gap-4 py-1.5">
          <dt className="min-w-0 text-xs text-ovcs-muted">{label}</dt>
          <dd className="whitespace-nowrap text-right text-sm tabular-nums">
            <Lines value={value} />
          </dd>
        </div>
      ))}
    </dl>
  )
}
