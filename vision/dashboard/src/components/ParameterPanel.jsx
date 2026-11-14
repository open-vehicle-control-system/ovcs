import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { groupParameters, useParameters } from '../stores/parameters.js'
import { OvcsBadge, OvcsParameterControl, formatValue, rangeStep, tidy, focusClass as FOCUS } from '@ovcs/ui/react'
import { computeTags } from '../compute.js'

// A relation is strict: the margin is the smallest step between two values.
const margin = (parameter) => (parameter.valueType === 'integer' ? 1 : rangeStep(parameter))

function relationBounds(parameter, parameters, below) {
  const { constraint } = parameter
  if (constraint?.kind !== 'range') return undefined
  let { min, max } = constraint
  const lower = parameters[parameter.greaterThan]?.value
  if (lower != null) min = Math.max(min, tidy(lower + margin(parameter)))
  for (const id of below.get(parameter.id) ?? []) {
    const upper = parameters[id]?.value
    if (upper != null) max = Math.min(max, tidy(upper - margin(parameter)))
  }
  return { min, max }
}

/**
 * What the live region says: the values a poll brought, as `name value`. Showing a group says nothing, nor does a
 * value committed here (`commit` notes it first) or one set by an automatic mode, which changes at every poll.
 */
function useChangedValues(groupId, members) {
  const shown = useRef(null)
  const committed = useRef(new Map())
  const [changed, setChanged] = useState('')

  useEffect(() => {
    const previous = shown.current
    shown.current = { groupId, values: new Map(members.map((parameter) => [parameter.id, parameter.value])) }
    if (previous?.groupId !== groupId) {
      setChanged('')
      return
    }
    const brought = members.filter((parameter) => {
      if (!previous.values.has(parameter.id) || previous.values.get(parameter.id) === parameter.value) return false
      const own = committed.current.get(parameter.id) === parameter.value
      committed.current.delete(parameter.id)
      return !own && parameter.state !== 'automatic'
    })
    if (brought.length === 0) return
    setChanged(brought.map((parameter) => `${parameter.name} ${formatValue(parameter.value)}`).join(', '))
  }, [groupId, members])

  return { changed, commit: (id, value) => committed.current.set(id, value) }
}

/** The group's summary, with its explanation behind a toggle on a line of its own, under it, that stays as set from one group to the next. */
function Summary({ summary, explanation }) {
  const explanationId = useId()
  const [open, setOpen] = useState(false)
  if (!summary && !explanation) return null

  return (
    <>
      <p className="mt-3 text-sm text-ovcs-text">{summary}</p>
      {explanation ? (
        <div className="mt-1 flex text-sm">
          <button
            type="button"
            aria-expanded={open}
            aria-controls={explanationId}
            onClick={() => setOpen((shown) => !shown)}
            className={`inline-flex min-h-6 items-center gap-0.5 rounded text-ovcs-accent-text hover:underline ${FOCUS}`}
          >
            How it works
            <svg
              aria-hidden="true"
              viewBox="0 0 16 16"
              fill="currentColor"
              className={`size-3 transition-transform motion-reduce:transition-none ${open ? 'rotate-90' : ''}`}
            >
              <path d="M6 3.5 10.5 8 6 12.5Z" />
            </svg>
          </button>
        </div>
      ) : null}
      {explanation ? (
        <p id={explanationId} data-explanation hidden={!open} className="mt-1.5 text-sm leading-relaxed text-ovcs-muted">
          {explanation}
        </p>
      ) : null}
    </>
  )
}

/** The selected group's name, summary and explanation, and its parameters, each with its control. */
export default function ParameterPanel({ groupId }) {
  const headingId = useId()
  const groups = useParameters((state) => state.groups)
  const parameters = useParameters((state) => state.parameters)
  const set = useParameters((state) => state.set)
  const reset = useParameters((state) => state.reset)
  const beginEdit = useParameters((state) => state.beginEdit)
  const endEdit = useParameters((state) => state.endEdit)

  const group = groups.find((candidate) => candidate.id === groupId)

  const members = useMemo(() => groupParameters({ groups, parameters }, groupId), [groups, parameters, groupId])

  // Parameters that must stay below another, by the id of the one above.
  const below = useMemo(() => {
    const index = new Map()
    for (const parameter of Object.values(parameters)) {
      if (parameter.greaterThan) index.set(parameter.greaterThan, [...(index.get(parameter.greaterThan) ?? []), parameter.id])
    }
    return index
  }, [parameters])

  const { changed, commit } = useChangedValues(groupId, members)

  if (!group) return <p className="text-sm text-ovcs-muted">Choose a box in the pipeline to see its parameters.</p>

  const tags = computeTags(group.compute)

  return (
    <section aria-labelledby={headingId}>
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <h2 id={headingId} translate="no" className="text-lg font-semibold">
            {group.name}
          </h2>
          {tags.length > 0 ? (
            <ul aria-label="Runs on" className="mt-1.5 flex flex-wrap gap-1.5">
              {tags.map((tag) => (
                <li key={tag}>
                  <OvcsBadge translate="no">{tag}</OvcsBadge>
                </li>
              ))}
            </ul>
          ) : null}
        </div>
        <button
          type="button"
          onClick={() => reset({ type: 'stages', id: group.id })}
          className={`min-h-8 shrink-0 rounded border border-ovcs-border px-2 text-sm hover:border-ovcs-accent ${FOCUS}`}
        >
          Reset <span translate="no">{group.name}</span>
        </button>
      </div>
      <Summary summary={group.summary} explanation={group.explanation} />
      <p aria-live="polite" className="sr-only">
        {changed}
      </p>
      <div className="divide-y divide-ovcs-border">
        {members.map((parameter) => (
          <OvcsParameterControl
            key={parameter.id}
            parameter={parameter}
            bounds={relationBounds(parameter, parameters, below)}
            controllerName={parameters[parameter.controlledBy]?.name}
            onChange={(value) => {
              commit(parameter.id, value)
              set(parameter.id, value)
            }}
            onReset={() => reset({ type: 'parameters', id: parameter.id })}
            onEditStart={() => beginEdit(parameter.id)}
            onEditEnd={() => endEdit(parameter.id)}
          />
        ))}
      </div>
    </section>
  )
}
