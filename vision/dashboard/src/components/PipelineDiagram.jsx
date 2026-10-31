import { useId, useMemo } from 'react'
import { flowGroups, groupUnsaved, sideGroups, useParameters } from '../stores/parameters.js'
import { OvcsBadge, focusClass as FOCUS } from '@ovcs/ui/react'
import { SECTION_HEADING, SELECTED } from './menu.js'
import { useNavigation } from '../stores/navigation.js'
import { computeTags } from '../compute.js'

// A warning item keeps its red border when selected.

const STATUS_STYLES = {
  ok: { border: 'border-transparent', dot: null },
  warning: { border: 'border-ovcs-error', dot: 'ovcs-status ovcs-status--error' },
  off: { border: 'border-dashed border-ovcs-border text-ovcs-muted', dot: 'ovcs-status' }
}

function accessibleName(group, unsaved) {
  const parts = [group.name]
  const tags = computeTags(group.compute)
  if (tags.length > 0) parts.push(`on ${tags.join(', ')}`)
  if (unsaved > 0) parts.push(`${unsaved} unsaved`)
  if (group.status) parts.push(group.status.detail ? `${group.status.level}: ${group.status.detail}` : group.status.level)
  return parts.join(', ')
}

function GroupBox({ group, unsaved, selected, onSelect }) {
  const style = STATUS_STYLES[group.status?.level] ?? STATUS_STYLES.ok
  const tags = computeTags(group.compute)
  return (
    <button
      type="button"
      aria-label={accessibleName(group, unsaved)}
      aria-current={selected ? 'true' : undefined}
      title={group.status?.detail}
      onClick={() => onSelect(group.id)}
      className={`flex min-h-9 w-full items-center gap-2 rounded border px-3 py-1 text-left text-sm ${style.border} ${
        selected ? `${SELECTED} font-medium` : 'hover:bg-ovcs-bg'
      } ${FOCUS}`}
    >
      <span className="flex min-w-0 flex-col gap-0.5">
        <span translate="no">{group.name}</span>
        {tags.length > 0 ? (
          <span aria-hidden="true" className="flex flex-wrap gap-1">
            {tags.map((tag) => (
              <span key={tag} data-tag translate="no" className="text-[10px] font-normal leading-none text-ovcs-muted">
                {tag}
              </span>
            ))}
          </span>
        ) : null}
      </span>
      {group.status && style.dot ? <span aria-hidden="true" className={`ml-auto ${style.dot}`} /> : null}
      <OvcsBadge tone="warn" aria-hidden="true" className={`min-w-4 text-center tabular-nums ${unsaved > 0 ? '' : 'invisible'} ${group.status && style.dot ? '' : 'ml-auto'}`}>
        {unsaved}
      </OvcsBadge>
    </button>
  )
}

/** A step's number on the line running through the pipeline; the line above it is the arrow from the previous step. */
function Step({ number, first, last, selected }) {
  return (
    <span aria-hidden="true" className="relative flex h-full items-center justify-center">
      {first ? null : <span data-arrow className="absolute left-1/2 top-[-2px] h-1/2 border-l-2 border-ovcs-muted opacity-40" />}
      {last ? null : <span className="absolute bottom-[-2px] left-1/2 h-1/2 border-l-2 border-ovcs-muted opacity-40" />}
      <span
        className={`relative flex size-6 items-center justify-center rounded-full border-2 text-xs font-semibold tabular-nums ${
          selected ? 'border-ovcs-accent bg-ovcs-accent text-white' : 'border-ovcs-border bg-ovcs-surface text-ovcs-muted'
        }`}
      >
        {number}
      </span>
    </span>
  )
}

/** The vision unit as a menu: its flow of boxes, one per line, the side groups apart; a box selects its group. */
export default function PipelineDiagram() {
  const sideId = useId()
  const groups = useParameters((state) => state.groups)
  const parameters = useParameters((state) => state.parameters)
  const onPipeline = useNavigation((state) => state.page === 'pipeline')
  const go = useNavigation((state) => state.go)
  const selectedGroupId = useParameters((state) => (onPipeline ? state.selectedGroupId : null))
  const selectGroup = useParameters((state) => state.select)
  const select = (id) => {
    selectGroup(id)
    go('pipeline')
  }

  const { flow, side } = useMemo(() => ({ flow: flowGroups({ groups }), side: sideGroups({ groups }) }), [groups])

  const unsaved = (group) => groupUnsaved({ groups, parameters }, group.id)

  const box = (group) => (
    <GroupBox group={group} unsaved={unsaved(group)} selected={group.id === selectedGroupId} onSelect={select} />
  )

  return (
    <div className="flex flex-col gap-4">
      <ol aria-label="Pipeline" className="flex flex-col">
        {flow.map((group, index) => (
          <li key={group.id} className="grid grid-cols-[1.5rem_minmax(0,1fr)] items-center gap-2 py-0.5">
            <Step number={index + 1} first={index === 0} last={index === flow.length - 1} selected={group.id === selectedGroupId} />
            {box(group)}
          </li>
        ))}
      </ol>
      {side.length > 0 ? (
        <div className="flex flex-col gap-2 border-t border-dashed border-ovcs-border pt-3">
          <span id={sideId} className={SECTION_HEADING}>
            Beside the pipeline
          </span>
          <ul aria-labelledby={sideId} className="flex flex-col gap-2">
            {side.map((group) => (
              <li key={group.id}>{box(group)}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  )
}
