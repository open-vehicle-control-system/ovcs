import { useId } from 'react'
import { focusClass as FOCUS, useOvcsRangeEdit } from '@ovcs/ui/react'
import Hint from './Hint.jsx'
import { HINTS } from '../hints.js'

const MIN = 0.5
const MAX = 50
const STEP = 0.5
const INFINITY = MAX + STEP
// The depth video's colour map, near to far, towards `side`.
const colours = (side) => `linear-gradient(to ${side}, #7a0403, #e4460a, #fba938, #a4fc3c, #2ee5ae, #3e9bfe, #4145ab)`

const show = (metres) => (metres === 0 ? '∞' : `${metres.toFixed(1)} m`)
const toSlider = (metres) => (metres === 0 ? INFINITY : metres)
const fromSlider = (position) => (position > MAX ? 0 : position)

/**
 * The depth video's colour range, `metres`, the distance coloured blue, set on the unit with `set` as soon as it is
 * released (`useOvcsRangeEdit`); 0, the slider's last notch, is ∞. `set` answers a promise of the range in force. `onChange` gets the range
 * to show: the one chosen, then the unit's answer, or the previous one again when the unit refuses it. It is the unit's, shared by every dashboard, and
 * a view setting: nothing to save, back to the composer's at the next boot. It lies along a line, near to far from
 * left to right, or, `vertical`, stands as tall as the room it has: near at the bottom, far and the range at the top.
 * The colour map is the slider's track.
 */
export default function DepthRange({ set, metres, onChange, vertical = false }) {
  const labelId = useId()
  const { draft, change, handlers } = useOvcsRangeEdit({
    value: metres,
    onCommit: (chosen) => {
      onChange(chosen)
      set(chosen).then(onChange, () => onChange(metres))
    }
  })

  if (metres === null) return null

  const shown = draft ?? metres

  const label = (
    <span className="flex items-center gap-1 text-xs text-ovcs-muted">
      <span id={labelId}>colour scale</span>
      <Hint hint={HINTS.colourScale} />
    </span>
  )
  // The colour map is the slider's own track, near to far along it.
  const slider = (className, side, orientation) => (
    <input
      type="range"
      data-colours
      aria-labelledby={labelId}
      aria-orientation={orientation}
      aria-valuetext={`blue at ${show(shown)}`}
      min={MIN}
      max={INFINITY}
      step={STEP}
      value={toSlider(shown)}
      {...handlers}
      onChange={(event) => change(fromSlider(Number(event.target.value)))}
      style={{ '--colours': colours(side) }}
      className={`colour-slider rounded-full ${className} ${FOCUS}`}
    />
  )

  if (vertical) {
    return (
      <div data-colour-scale data-orientation="vertical" className="flex min-h-0 flex-1 select-none flex-col items-start gap-2">
        {label}
        <span className="whitespace-nowrap text-base font-semibold tabular-nums">{show(shown)}</span>
        {/* A vertical writing mode stands the slider up; right to left, its maximum is at the top. */}
        {slider('min-h-0 w-4 flex-1 [direction:rtl] [writing-mode:vertical-lr]', 'top', 'vertical')}
        <span className="text-xs text-ovcs-muted">near</span>
      </div>
    )
  }

  return (
    <div data-colour-scale data-orientation="horizontal" className="flex select-none flex-col gap-1">
      {label}
      <span className="flex items-center gap-2">
        <span className="text-xs text-ovcs-muted">near</span>
        {slider('h-4 min-w-12 flex-1', 'right')}
        <span className="w-16 whitespace-nowrap text-base font-semibold tabular-nums">{show(shown)}</span>
      </span>
    </div>
  )
}
