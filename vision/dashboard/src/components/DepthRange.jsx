import { useId, useState } from 'react'
import { focusClass as FOCUS } from '@ovcs/ui/react'
import Hint from './Hint.jsx'
import { HINTS } from '../hints.js'

const MIN = 0.5
const MAX = 50
const STEP = 0.5
const INFINITY = MAX + STEP
// The depth video's colour map, near to far.
const COLOURS = 'linear-gradient(to right, #7a0403, #e4460a, #fba938, #a4fc3c, #2ee5ae, #3e9bfe, #4145ab)'

const show = (metres) => (metres === 0 ? '∞' : `${metres.toFixed(1)} m`)
const toSlider = (metres) => (metres === 0 ? INFINITY : metres)
const fromSlider = (position) => (position > MAX ? 0 : position)

/**
 * The depth video's colour range, `metres`, the distance coloured blue, set on the depth stream's `channel` as soon as
 * it is released; 0, the slider's last notch, is ∞. `onChange` gets the range to show: the one chosen, then the
 * unit's answer, or the previous one again when the unit refuses it. It is the unit's, shared by every dashboard, and
 * a view setting: nothing to save, back to the composer's at the next boot.
 */
export default function DepthRange({ channel, metres, onChange }) {
  const labelId = useId()
  const [draft, setDraft] = useState(null)

  if (!channel || metres === null) return null

  const shown = draft ?? metres
  const finish = () => {
    if (draft === null) return
    const chosen = draft
    setDraft(null)
    if (chosen === metres) return
    onChange(chosen)
    channel
      .push('depth_range', { metres: chosen })
      .receive('ok', (reply) => onChange(reply.metres))
      .receive('error', () => onChange(metres))
  }

  return (
    <div data-colour-scale className="flex select-none flex-col gap-1">
      <div className="flex items-center gap-2">
        <span className="flex items-center gap-1 text-xs text-ovcs-muted">
          <span id={labelId}>colour scale</span>
          <Hint hint={HINTS.colourScale} />
        </span>
        <span className="text-xs text-ovcs-muted">near</span>
        <span aria-hidden="true" className="h-2 min-w-12 flex-1 rounded-sm" style={{ backgroundImage: COLOURS }} />
        <span className="w-16 whitespace-nowrap text-base font-semibold tabular-nums">{show(shown)}</span>
      </div>
      <input
        type="range"
        aria-labelledby={labelId}
        aria-valuetext={`blue at ${show(shown)}`}
        min={MIN}
        max={INFINITY}
        step={STEP}
        value={toSlider(shown)}
        onChange={(event) => setDraft(fromSlider(Number(event.target.value)))}
        onPointerUp={finish}
        onKeyUp={finish}
        onBlur={finish}
        className={`h-4 w-full accent-ovcs-accent ${FOCUS}`}
      />
    </div>
  )
}
