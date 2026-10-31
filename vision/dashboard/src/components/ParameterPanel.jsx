import { useId, useMemo } from 'react'
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

/** The selected group's name, summary and parameters, each with its control. */
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

  if (!group) return <p className="text-sm text-ovcs-muted">Choose a box in the pipeline to see its parameters.</p>

  const tags = computeTags(group.compute)

  // Values set by an automatic mode change at every poll; announcing them would be noise.
  const summary = members
    .flatMap((parameter) => (parameter.state === 'automatic' ? [] : [`${parameter.name} ${formatValue(parameter.value)}`]))
    .join(', ')

  return (
    <section aria-labelledby={headingId}>
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <h2 id={headingId} translate="no" className="text-lg font-semibold">
            {group.name}
          </h2>
          {group.summary ? <p className="text-sm text-ovcs-muted">{group.summary}</p> : null}
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
      <p aria-live="polite" className="sr-only">
        {summary}
      </p>
      <div className="divide-y divide-ovcs-border">
        {members.map((parameter) => (
          <OvcsParameterControl
            key={parameter.id}
            parameter={parameter}
            bounds={relationBounds(parameter, parameters, below)}
            controllerName={parameters[parameter.controlledBy]?.name}
            onChange={(value) => set(parameter.id, value)}
            onReset={() => reset({ type: 'parameters', id: parameter.id })}
            onEditStart={() => beginEdit(parameter.id)}
            onEditEnd={() => endEdit(parameter.id)}
          />
        ))}
      </div>
    </section>
  )
}
