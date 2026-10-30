import { useId, useMemo } from 'react'
import { flowGroups, groupUnsaved, sideGroups, useParameters } from '../stores/parameters.js'
import { FOCUS } from './styles.js'

// Selection is a tint and a bar on the bottom edge, unlike the focus outline; a warning box keeps its red border.
const SELECTED = 'shadow-[inset_0_-3px_0_var(--ovcs-accent)] bg-[color-mix(in_srgb,var(--ovcs-accent)_12%,var(--ovcs-surface))]'

const STATUS_STYLES = {
  ok: { border: 'border-ovcs-border', dot: 'ovcs-status ovcs-status--ok' },
  warning: { border: 'border-ovcs-error', dot: 'ovcs-status ovcs-status--error' },
  off: { border: 'border-dashed border-ovcs-border text-ovcs-muted', dot: 'ovcs-status' }
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
      className={`inline-flex min-h-9 items-center gap-2 rounded border px-3 text-sm hover:border-ovcs-accent ${style.border} ${
        selected ? SELECTED : 'bg-ovcs-surface'
      } ${FOCUS}`}
    >
      {group.status ? <span aria-hidden="true" className={style.dot} /> : null}
      <span translate="no">{group.name}</span>
      <span aria-hidden="true" className={`ovcs-badge ovcs-badge--warn min-w-4 text-center tabular-nums ${unsaved > 0 ? '' : 'invisible'}`}>
        {unsaved}
      </span>
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

  const { flow, side } = useMemo(() => ({ flow: flowGroups({ groups }), side: sideGroups({ groups }) }), [groups])

  const unsaved = (group) => groupUnsaved({ groups, parameters }, group.id)

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
