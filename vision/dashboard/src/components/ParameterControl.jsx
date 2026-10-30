import { useId, useRef, useState } from 'react'

const FOCUS = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ovcs-accent'
const BUTTON = `min-h-8 rounded border border-ovcs-border px-2 text-sm disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`
const KEYS_THAT_STEP = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End'])
const STATE_LABELS = { builtin: 'built-in', saved: 'saved', unsaved: 'unsaved' }

export const formatValue = (value) => {
  if (value == null) return '–'
  if (typeof value === 'boolean') return value ? 'on' : 'off'
  return String(value)
}

/** The step of a range: its own, else 1 for an integer and a hundredth of the range for a double. */
export function rangeStep({ type, constraint }) {
  if (constraint?.step) return constraint.step
  if (type === 'integer') return 1
  return tidy((constraint.max - constraint.min) / 100)
}

/** Rounds away floating-point noise from sums of steps. */
export const tidy = (number) => Number(number.toPrecision(12))

const sameValue = (a, b) => a === b || (typeof a === 'number' && typeof b === 'number' && tidy(a) === tidy(b))

function fit(number, parameter, bounds) {
  const { type, constraint } = parameter
  let value = number
  if (constraint?.step) value = tidy(constraint.min + Math.round((value - constraint.min) / constraint.step) * constraint.step)
  else if (type === 'integer') value = Math.round(value)
  if (bounds) value = Math.min(bounds.max, Math.max(bounds.min, value))
  return value
}

function parseNumber(text) {
  const trimmed = text.trim().replace(',', '.')
  if (trimmed === '') return null
  const number = Number(trimmed)
  return Number.isFinite(number) ? number : null
}

/** A text field holding a value, committed on Enter or blur; numbers are fitted to the bounds. */
function ValueField({ parameter, shown, bounds, label, onChange }) {
  const [text, setText] = useState(null)
  const disabled = parameter.value == null
  const numeric = parameter.type === 'integer' || parameter.type === 'double'

  const commit = () => {
    if (text === null) return
    setText(null)
    let value = text
    if (numeric) {
      const number = parseNumber(text)
      if (number === null) return
      value = fit(number, parameter, bounds)
    }
    if (!sameValue(value, parameter.value)) onChange(value)
  }

  return (
    <input
      type="text"
      inputMode={numeric ? 'decimal' : 'text'}
      aria-label={label}
      disabled={disabled}
      value={disabled ? '–' : text ?? formatValue(shown)}
      onFocus={() => setText(formatValue(shown))}
      onChange={(event) => setText(event.target.value)}
      onBlur={commit}
      onKeyDown={(event) => {
        if (event.key === 'Enter') commit()
        if (event.key === 'Escape') setText(null)
      }}
      className={`w-20 rounded border border-ovcs-border bg-ovcs-bg px-2 py-1 text-right text-sm tabular-nums disabled:opacity-50 ${FOCUS}`}
    />
  )
}

/** A slider and its number; a drag or key press is committed once, when released. */
function RangeControl({ parameter, bounds, labelId, name, onChange, onEditStart, onEditEnd }) {
  const [draft, setDraft] = useState(null)
  const draftRef = useRef(null)
  const editing = useRef(false)
  const disabled = parameter.value == null
  const shown = draft ?? parameter.value

  const begin = () => {
    if (editing.current) return
    editing.current = true
    onEditStart?.()
  }

  const finish = () => {
    if (!editing.current) return
    editing.current = false
    const value = draftRef.current
    draftRef.current = null
    setDraft(null)
    if (value !== null && !sameValue(value, parameter.value)) onChange(value)
    onEditEnd?.()
  }

  const move = (event) => {
    const value = Number(event.target.value)
    if (!editing.current) {
      if (!sameValue(value, parameter.value)) onChange(value)
      return
    }
    draftRef.current = value
    setDraft(value)
  }

  return (
    <div className="flex items-center gap-3">
      <input
        type="range"
        aria-labelledby={labelId}
        min={bounds.min}
        max={bounds.max}
        step={rangeStep(parameter)}
        value={disabled ? bounds.min : shown}
        disabled={disabled}
        onPointerDown={(event) => {
          event.currentTarget.setPointerCapture?.(event.pointerId)
          begin()
        }}
        onPointerUp={finish}
        onPointerCancel={finish}
        onLostPointerCapture={finish}
        onKeyDown={(event) => {
          if (KEYS_THAT_STEP.has(event.key)) begin()
        }}
        onKeyUp={finish}
        onBlur={finish}
        onChange={move}
        className={`h-6 min-w-0 flex-1 accent-ovcs-accent disabled:opacity-50 ${FOCUS}`}
      />
      <ValueField parameter={parameter} shown={shown} bounds={bounds} label={`${name} value`} onChange={onChange} />
    </div>
  )
}

function ChoiceControl({ parameter, labelId, onChange }) {
  const disabled = parameter.value == null
  return (
    <div className="flex flex-wrap items-center gap-2">
      <div role="group" aria-labelledby={labelId} className="flex flex-wrap gap-2">
        {parameter.constraint.values.map((choice) => (
          <button
            key={String(choice)}
            type="button"
            aria-pressed={choice === parameter.value}
            disabled={disabled}
            onClick={() => onChange(choice)}
            className={`${BUTTON} aria-pressed:border-ovcs-accent aria-pressed:bg-ovcs-accent aria-pressed:text-ovcs-bg`}
          >
            {formatValue(choice)}
          </button>
        ))}
      </div>
      {disabled ? <span className="text-sm text-ovcs-muted">–</span> : null}
    </div>
  )
}

function SwitchControl({ parameter, labelId, onChange }) {
  const on = parameter.value === true
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-labelledby={labelId}
      disabled={parameter.value == null}
      onClick={() => onChange(!on)}
      className={`inline-flex min-h-8 items-center gap-2 rounded px-1 text-sm disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`}
    >
      <span aria-hidden="true" className={`relative h-5 w-9 rounded-full transition-colors ${on ? 'bg-ovcs-accent' : 'bg-ovcs-border'}`}>
        <span className={`absolute top-0.5 h-4 w-4 rounded-full bg-ovcs-surface transition-transform ${on ? 'translate-x-4' : 'translate-x-0.5'}`} />
      </span>
      <span>{formatValue(parameter.value)}</span>
    </button>
  )
}

function LockIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" className="h-3.5 w-3.5 fill-current">
      <path d="M5 7V5a3 3 0 0 1 6 0v2h1v7H4V7h1Zm1.5 0h3V5a1.5 1.5 0 0 0-3 0v2Z" />
    </svg>
  )
}

function ReadOnlyValue({ parameter, icon }) {
  return (
    <p className="flex items-center gap-1.5 text-sm tabular-nums text-ovcs-muted">
      {icon}
      <span>{formatValue(parameter.value)}</span>
    </p>
  )
}

function EditableControl({ parameter, bounds, labelId, onChange, onEditStart, onEditEnd }) {
  switch (parameter.constraint?.kind) {
    case 'range':
      return (
        <RangeControl
          parameter={parameter}
          bounds={bounds}
          labelId={labelId}
          name={parameter.name}
          onChange={onChange}
          onEditStart={onEditStart}
          onEditEnd={onEditEnd}
        />
      )
    case 'choices':
      return <ChoiceControl parameter={parameter} labelId={labelId} onChange={onChange} />
    case 'bool':
      return <SwitchControl parameter={parameter} labelId={labelId} onChange={onChange} />
    default:
      return <ValueField parameter={parameter} shown={parameter.value} label={`${parameter.name} value`} onChange={onChange} />
  }
}

function allowed(constraint, bounds) {
  switch (constraint?.kind) {
    case 'range':
      return `allows ${bounds.min} to ${bounds.max}${constraint.step ? `, step ${constraint.step}` : ''}`
    case 'choices':
      return `one of ${constraint.values.map(formatValue).join(', ')}`
    case 'bool':
      return 'on or off'
    default:
      return null
  }
}

/**
 * One parameter: its control, badge, description, what it allows, saved state and default.
 *
 * `bounds` narrows a range (for relations between parameters); `onChange` receives a committed
 * value, `onEditStart` and `onEditEnd` wrap a slider drag.
 */
export default function ParameterControl({ parameter, bounds, controllerName, onChange, onReset, onEditStart, onEditEnd }) {
  const labelId = useId()
  const locked = parameter.applies === 'build'
  const automatic = !locked && parameter.state === 'automatic'
  const editable = !locked && !automatic
  const changed = editable && parameter.value != null && !sameValue(parameter.value, parameter.default)
  const constraint = parameter.constraint
  const range = bounds ?? (constraint?.kind === 'range' ? { min: constraint.min, max: constraint.max } : null)
  const allows = allowed(constraint, range)

  let badge = 'live'
  if (locked) badge = 'build'
  if (automatic) badge = 'automatic'

  let control
  if (locked) control = <ReadOnlyValue parameter={parameter} icon={<LockIcon />} />
  else if (automatic) control = <ReadOnlyValue parameter={parameter} />
  else {
    control = (
      <EditableControl
        parameter={parameter}
        bounds={range}
        labelId={labelId}
        onChange={onChange}
        onEditStart={onEditStart}
        onEditEnd={onEditEnd}
      />
    )
  }

  return (
    <div className="flex flex-col gap-1.5 py-3">
      <div className="flex items-center gap-2">
        <span id={labelId} className="font-mono text-sm font-medium">
          {parameter.name}
        </span>
        <span className="ovcs-badge">{badge}</span>
        {automatic ? <span className="text-xs text-ovcs-muted">set by {controllerName ?? 'an automatic mode'}</span> : null}
        {editable && STATE_LABELS[parameter.state] ? (
          <span className={`ml-auto text-xs ${parameter.state === 'unsaved' ? 'text-ovcs-warn' : 'text-ovcs-muted'}`}>
            {STATE_LABELS[parameter.state]}
          </span>
        ) : null}
      </div>
      {control}
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-ovcs-muted">
        {parameter.description ? <span>{parameter.description}</span> : null}
        {allows ? <span className="tabular-nums">{allows}</span> : null}
        {changed ? (
          <>
            <span className="tabular-nums">default {formatValue(parameter.default)}</span>
            <button type="button" onClick={onReset} className={`${BUTTON} ml-auto text-xs`}>
              Reset {parameter.name}
            </button>
          </>
        ) : null}
      </div>
    </div>
  )
}
