import { useMemo } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { pipelines as pipelinesOf, unsavedByGroup, useParameters } from '../stores/parameters.js'
import { OvcsBadge, OvcsMenuItem } from '@ovcs/ui/react'
import { STATUS_STYLES, SUBSECTION_HEADING } from './menu.js'
import { useNavigation } from '../stores/navigation.js'
import { useStatus } from '../stores/status.js'
import { formatNumber } from '../status.js'
import { computeTags } from '../compute.js'

function accessibleName(group, unsaved, figure) {
  const parts = [group.name]
  const tags = computeTags(group.compute)
  if (tags.length > 0) parts.push(`on ${tags.join(', ')}`)
  if (figure) parts.push(figure)
  if (unsaved > 0) parts.push(`${unsaved} unsaved`)
  if (group.status) parts.push(group.status.detail ? `${group.status.level}: ${group.status.detail}` : group.status.level)
  return parts.join(', ')
}

const milliseconds = (ms) => `${formatNumber(ms)} ms`

// A step's name in its pipeline's times: the last segment of its id.
const stageName = (group) => group.id.slice(group.id.lastIndexOf('.') + 1)

// The time of the steps computed together that `stage` is the first of, with the numbers of the steps it covers.
function segmentTime(times, stage, steps) {
  const segment = times?.segments?.find((candidate) => candidate.stages[0] === stage)
  if (!segment) return null
  const numbers = segment.stages.map((name) => steps.findIndex((step) => stageName(step) === name) + 1).filter((number) => number > 0)
  const [first, last] = [numbers[0], numbers[numbers.length - 1]]
  return last > first ? `${milliseconds(segment.ms)} for steps ${first} to ${last}` : milliseconds(segment.ms)
}

/**
 * What the unit status says of the time of `group`, a step of the pipeline whose steps are `steps`: its mean time per
 * pair or frame, then for an Inference step the time its accelerator took of it. A source has none.
 */
function stageFigure(snapshot, group, steps) {
  if (group.role === 'source') return null
  const times = snapshot?.pipelines?.[group.pipeline]
  const stage = stageName(group)
  const own = times?.stages?.[stage]
  const accelerator = stage === 'inference' ? snapshot?.npu?.pipelines?.[group.pipeline]?.inferenceMs : null
  const parts = [own == null ? segmentTime(times, stage, steps) : milliseconds(own), accelerator == null ? null : `NPU ${milliseconds(accelerator)}`]
  return parts.filter(Boolean).join(', ') || null
}

function GroupBox({ group, steps, unsaved, selected, onSelect }) {
  const style = STATUS_STYLES[group.status?.level] ?? STATUS_STYLES.ok
  const tags = computeTags(group.compute)
  const figure = useStatus((state) => stageFigure(state.snapshot, group, steps))
  return (
    <OvcsMenuItem
      selected={selected}
      aria-label={accessibleName(group, unsaved, figure)}
      aria-current={selected ? 'true' : undefined}
      title={group.status?.detail}
      onClick={() => onSelect(group.id)}
      className={`border py-1 ${style.border}`}
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
        {figure ? (
          <span aria-hidden="true" data-figure className="text-[10px] font-normal leading-none tabular-nums text-ovcs-muted">
            {figure}
          </span>
        ) : null}
      </span>
      {group.status && style.dot ? <span aria-hidden="true" className={`ml-auto ${style.dot}`} /> : null}
      <OvcsBadge tone="warn" aria-hidden="true" className={`min-w-4 text-center tabular-nums ${unsaved > 0 ? '' : 'invisible'} ${group.status && style.dot ? '' : 'ml-auto'}`}>
        {unsaved}
      </OvcsBadge>
    </OvcsMenuItem>
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

// The pipelines with their groups, and how to draw a group as a box that selects it.
function useGroupBoxes() {
  const groups = useParameters((state) => state.groups)
  // The counts alone, so a value changing every poll, such as an exposure, does not render the menu again.
  const unsaved = useParameters(useShallow(unsavedByGroup))
  const onPipeline = useNavigation((state) => state.page === 'pipeline')
  const go = useNavigation((state) => state.go)
  const selectedGroupId = useParameters((state) => (onPipeline ? state.selectedGroupId : null))
  const selectGroup = useParameters((state) => state.select)
  const select = (id) => {
    selectGroup(id)
    go('pipeline')
  }

  const pipelines = useMemo(() => pipelinesOf({ groups }), [groups])

  const box = (group, steps) => (
    <GroupBox group={group} steps={steps} unsaved={unsaved[group.id] ?? 0} selected={group.id === selectedGroupId} onSelect={select} />
  )

  return { pipelines, selectedGroupId, box }
}

// `lane_detection` reads as "Lane detection".
const title = (name) => {
  const words = String(name).replaceAll('_', ' ')
  return words.charAt(0).toUpperCase() + words.slice(1)
}

/** A pipeline's name, with the time one pair or frame takes it once the unit status reports it, over what it shows. */
function Pipeline({ name, children }) {
  const totalMs = useStatus((state) => state.snapshot?.pipelines?.[name]?.totalMs)
  return (
    <div className="flex flex-col gap-1">
      <h3 className={SUBSECTION_HEADING}>
        {title(name)}
        {totalMs == null ? null : (
          <span data-total className="font-normal tabular-nums text-ovcs-muted">
            {' '}
            {milliseconds(totalMs)}
          </span>
        )}
      </h3>
      {children}
    </div>
  )
}

/** A pipeline's steps as numbered boxes, one per line. */
function Steps({ name, groups, selectedGroupId, box }) {
  return (
    <ol aria-label={title(name)} className="flex flex-col">
      {groups.map((group, index) => (
        <li key={group.id} className="grid grid-cols-[1.5rem_minmax(0,1fr)] items-center gap-2 py-0.5">
          <Step number={index + 1} first={index === 0} last={index === groups.length - 1} selected={group.id === selectedGroupId} />
          {box(group, groups)}
        </li>
      ))}
    </ol>
  )
}

/**
 * The vision unit's pipelines as a menu, each a numbered flow of boxes that select their group. Detection is listed on
 * every unit, so the menu reads the same everywhere: on a unit with no pipeline beyond the stereo one, as one greyed line.
 */
export default function Pipelines() {
  const { pipelines, selectedGroupId, box } = useGroupBoxes()
  if (pipelines.length === 0) return null
  const withInference = pipelines.some((pipeline) => pipeline.name !== 'stereo')

  return (
    <div className="flex flex-col gap-3">
      {pipelines.map(({ name, groups }) => (
        <Pipeline key={name} name={name}>
          <Steps name={name} groups={groups} selectedGroupId={selectedGroupId} box={box} />
        </Pipeline>
      ))}
      {withInference ? null : (
        <Pipeline name="detection">
          <p className="px-3 py-1 text-sm text-ovcs-muted">No detector on this unit</p>
        </Pipeline>
      )}
    </div>
  )
}
