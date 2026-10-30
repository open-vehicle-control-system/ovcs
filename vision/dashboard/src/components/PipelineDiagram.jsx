import { useId, useMemo } from 'react'
import { useParameters } from '../stores/parameters.js'

const FOCUS = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ovcs-accent'

const STATUS_STYLES = {
  ok: { box: 'border-ovcs-border', dot: 'ovcs-status ovcs-status--ok' },
  warning: { box: 'border-ovcs-error', dot: 'ovcs-status ovcs-status--error' },
  off: { box: 'border-dashed border-ovcs-border text-ovcs-muted', dot: 'ovcs-status' }
}

function accessibleName(group, unsaved) {
  const parts = [group.name]
  if (unsaved > 0) parts.push(`${unsaved} unsaved`)
  if (group.status) parts.push(group.status.detail ? `${group.status.level}: ${group.status.detail}` : group.status.level)
  return parts.join(', ')
}

function GroupBox({ group, unsaved, selected, onSelect }) {
  const style = STATUS_STYLES[group.status?.level] ?? STATUS_STYLES.ok
  return (
    <button
      type="button"
      aria-label={accessibleName(group, unsaved)}
      aria-current={selected ? 'true' : undefined}
      title={group.status?.detail}
      onClick={() => onSelect(group.id)}
      className={`inline-flex min-h-9 items-center gap-2 rounded border bg-ovcs-surface px-3 text-sm ${style.box} ${
        selected ? 'ring-2 ring-ovcs-accent' : ''
      } ${FOCUS}`}
    >
      {group.status ? <span aria-hidden="true" className={style.dot} /> : null}
      <span>{group.name}</span>
      {unsaved > 0 ? (
        <span aria-hidden="true" className="ovcs-badge ovcs-badge--warn tabular-nums">
          {unsaved}
        </span>
      ) : null}
    </button>
  )
}

/** The vision unit as its flow of boxes, the side groups apart; a box selects its group. */
export default function PipelineDiagram() {
  const sideId = useId()
  const groups = useParameters((state) => state.groups)
  const parameters = useParameters((state) => state.parameters)
  const selectedGroupId = useParameters((state) => state.selectedGroupId)
  const select = useParameters((state) => state.select)

  const { flow, side } = useMemo(() => {
    const ordered = groups.toSorted((a, b) => a.position - b.position)
    return {
      flow: ordered.filter((group) => group.placement === 'flow'),
      side: ordered.filter((group) => group.placement === 'side')
    }
  }, [groups])

  const unsaved = (group) => group.parameterIds.filter((id) => parameters[id]?.state === 'unsaved').length

  const box = (group) => (
    <GroupBox group={group} unsaved={unsaved(group)} selected={group.id === selectedGroupId} onSelect={select} />
  )

  return (
    <div className="flex flex-col gap-3">
      <ol aria-label="Pipeline" className="flex flex-wrap items-center gap-y-2">
        {flow.map((group, index) => (
          <li key={group.id} className="flex items-center">
            {index > 0 ? (
              <span data-arrow aria-hidden="true" className="px-1.5 text-ovcs-muted">
                →
              </span>
            ) : null}
            {box(group)}
          </li>
        ))}
      </ol>
      {side.length > 0 ? (
        <div className="flex flex-wrap items-center gap-2 border-t border-dashed border-ovcs-border pt-3">
          <span id={sideId} className="text-xs text-ovcs-muted">
            Beside the pipeline
          </span>
          <ul aria-labelledby={sideId} className="flex flex-wrap gap-2">
            {side.map((group) => (
              <li key={group.id}>{box(group)}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  )
}
