import { useEffect, useId, useState } from 'react'
import { focusClass as FOCUS } from '@ovcs/ui/react'
import Hint from './Hint.jsx'
import { HINTS } from '../hints.js'

const STORAGE_KEY = 'vision.v1.depth_range_m'
const MIN = 0.5
const MAX = 50
const STEP = 0.5
const INFINITY = MAX + STEP
// The depth video's colour map, near to far.
const COLOURS = 'linear-gradient(to right, #7a0403, #e4460a, #fba938, #a4fc3c, #2ee5ae, #3e9bfe, #4145ab)'

const show = (metres) => (metres === 0 ? '∞' : `${metres.toFixed(1)} m`)
const toSlider = (metres) => (metres === 0 ? INFINITY : metres)
const fromSlider = (position) => (position > MAX ? 0 : position)

function remembered() {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY)
    return value === null ? null : Number(value)
  } catch {
    return null
  }
}

function remember(metres) {
  try {
    window.localStorage.setItem(STORAGE_KEY, String(metres))
  } catch {
    // Without storage the range lasts until the page reloads.
  }
}

/**
 * The depth video's colour range, the distance coloured blue, set on the depth stream's `channel` as soon as it is
 * released; 0, the slider's last notch, is ∞. It is a view setting: nothing to save, and this browser remembers it.
 */
export default function DepthRange({ channel }) {
  const labelId = useId()
  const [value, setValue] = useState(null)
  const [draft, setDraft] = useState(null)

  useEffect(() => {
    if (!channel) return
    const stored = remembered()
    channel
      .push('depth_range', stored === null ? {} : { metres: stored })
      .receive('ok', ({ metres }) => setValue(metres))
  }, [channel])

  if (!channel || value === null) return null

  const shown = draft ?? value
  const finish = () => {
    if (draft === null) return
    const metres = draft
    setDraft(null)
    if (metres === value) return
    setValue(metres)
    channel
      .push('depth_range', { metres })
      .receive('ok', (reply) => {
        setValue(reply.metres)
        remember(reply.metres)
      })
      .receive('error', () => setValue(value))
  }

  return (
    <div data-figure="colour scale" className="ml-auto flex select-none flex-col gap-1">
      <div className="flex items-center gap-2">
        <span className="flex items-center gap-1 text-xs text-ovcs-muted">
          <span id={labelId}>colour scale</span>
          <Hint hint={HINTS.colourScale} />
        </span>
        <span className="text-xs text-ovcs-muted">near</span>
        <span aria-hidden="true" className="h-2 w-24 rounded-sm" style={{ backgroundImage: COLOURS }} />
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
