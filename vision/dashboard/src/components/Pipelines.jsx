import { useMemo } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { pipelines as pipelinesOf, unsavedByGroup, useParameters } from '../stores/parameters.js'
import { OvcsBadge, OvcsMenuItem } from '@ovcs/ui/react'
import { STATUS_STYLES, SUBSECTION_HEADING } from './menu.js'
import { useNavigation } from '../stores/navigation.js'
import { useStatus } from '../stores/status.js'
import { formatNumber } from '../status.js'
import { computeTags, runsOnTag } from '../compute.js'

function accessibleName(group, unsaved, figures) {
  const parts = [group.name]
  const tags = computeTags(group.compute)
  if (tags.length > 0) parts.push(`on ${tags.join(', ')}`)
  parts.push(...figures)
  if (unsaved > 0) parts.push(`${unsaved} unsaved`)
  if (group.status) parts.push(group.status.detail ? `${group.status.level}: ${group.status.detail}` : group.status.level)
  return parts.join(', ')
}

const milliseconds = (ms) => `${formatNumber(ms)} ms`

// A time at the end of a step's line or a pipeline's heading.
const FIGURE = 'ml-auto font-normal tabular-nums text-ovcs-muted'

// Ends a pipeline's total where its steps' times end, inside a box's border.
const TOTAL_INSET = 'mr-px'

// What each latency the unit status reports runs from and to, by the step it is shown on.
const LATENCY_NAMES = { cameras: 'capture to unit', pairing: 'wait to pair' }

// A step's name in its pipeline's times: the last segment of its id.
const stageName = (group) => group.id.slice(group.id.lastIndexOf('.') + 1)

// The numbers of the steps, among `steps`, that a run timed as one covers.
const stepNumbers = (segment, steps) =>
  segment.stages.map((name) => steps.findIndex((step) => stageName(step) === name) + 1).filter((number) => number > 0)

// The time of a run timed as one whose only step among `steps` is `stage`, which is then a step timed alone.
function aloneTime(times, stage, steps) {
  const segment = times?.segments?.find((candidate) => {
    const numbers = stepNumbers(candidate, steps)
    return numbers.length === 1 && stageName(steps[numbers[0] - 1]) === stage
  })
  return segment?.ms == null ? null : milliseconds(segment.ms)
}

/**
 * What the unit status says of the time of `group`, a step of the pipeline whose steps are `steps`: its mean time per
 * pair or frame. A source has none, nor has a step computed in one pass with others, whose time is theirs too.
 */
function stageTime(snapshot, group, steps) {
  if (group.role === 'source') return null
  const times = snapshot?.pipelines?.[group.pipeline]
  const stage = stageName(group)
  const own = times?.stages?.[stage]
  return own == null ? aloneTime(times, stage, steps) : milliseconds(own)
}

/** The time the accelerator took of `group` when it is an Inference step, as the unit status says it. */
function acceleratorTime(snapshot, group) {
  if (stageName(group) !== 'inference') return null
  const ms = snapshot?.npu?.pipelines?.[group.pipeline]?.inferenceMs
  return ms == null ? null : `NPU ${milliseconds(ms)}`
}

/** The latency the unit status reports on `group`: no step's work, so its pipeline's total leaves it out. */
function latencyTime(snapshot, group) {
  const ms = snapshot?.latencies?.[group.pipeline]?.[stageName(group)]
  return ms == null ? null : milliseconds(ms)
}

const latencyFigure = (group, latency) => `${LATENCY_NAMES[stageName(group)] ?? 'latency'} ${latency}, not in the total`

const NO_SEGMENTS = []

/** The runs of `steps` timed as one that cover two steps or more and have a time, each as the bracket that draws it. */
function timedRuns(segments, steps) {
  return segments.flatMap((segment) => {
    const numbers = stepNumbers(segment, steps)
    if (numbers.length < 2 || segment.ms == null) return []
    const places = new Set(numbers.map((number) => runsOnTag(steps[number - 1].compute)).filter(Boolean))
    return [{ first: numbers[0], last: numbers.at(-1), time: milliseconds(segment.ms), place: places.size === 1 ? [...places][0] : null }]
  })
}

/**
 * A bracket along the right of the rows of a run of steps computed in one pass, with its one time and where it runs.
 * It sits over the rows' grid, so it lets clicks through to them.
 */
function RunBracket({ first, last, time, place }) {
  return (
    <span
      role="img"
      aria-label={`Steps ${first} to ${last} run as one ${place ? `${place} ` : ''}pass, ${time}`}
      data-run
      data-first-step={first}
      data-last-step={last}
      style={{ gridRow: `${first} / ${last + 1}` }}
      className="pointer-events-none relative z-10 col-start-1 -mr-1 flex items-center justify-self-end py-1.5 pr-1"
    >
      <span translate="no" className="text-[11px] font-medium leading-none tabular-nums text-ovcs-text opacity-80 [writing-mode:vertical-rl]">
        {place ? `${time} · ${place}` : time}
      </span>
      <span className="absolute inset-y-1.5 right-0 w-2 rounded-r-sm border-y-2 border-r-2 border-ovcs-muted opacity-70" />
    </span>
  )
}

/** The brackets of the pipeline `name`'s runs of `steps` computed in one pass, from the unit status. */
function RunBrackets({ name, steps }) {
  const segments = useStatus((state) => state.snapshot?.pipelines?.[name]?.segments ?? NO_SEGMENTS)
  return timedRuns(segments, steps).map((run) => <RunBracket key={run.first} {...run} />)
}

function GroupBox({ group, steps, unsaved, selected, onSelect }) {
  const style = STATUS_STYLES[group.status?.level] ?? STATUS_STYLES.ok
  const tags = computeTags(group.compute)
  const time = useStatus((state) => stageTime(state.snapshot, group, steps))
  const accelerator = useStatus((state) => acceleratorTime(state.snapshot, group))
  const latency = useStatus((state) => latencyTime(state.snapshot, group))
  const figures = [time, accelerator, latency && latencyFigure(group, latency)].filter(Boolean)
  return (
    <OvcsMenuItem
      selected={selected}
      aria-label={accessibleName(group, unsaved, figures)}
      aria-current={selected ? 'true' : undefined}
      title={group.status?.detail}
      onClick={() => onSelect(group.id)}
      className={`border py-1 ${style.border}`}
    >
      <span className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span className="flex flex-wrap items-baseline gap-x-2">
          <span translate="no">{group.name}</span>
          {time ? (
            <span aria-hidden="true" data-time className={`text-[10px] ${FIGURE}`}>
              {time}
            </span>
          ) : null}
          {latency ? (
            <span aria-hidden="true" data-latency className={`text-[10px] ${FIGURE}`}>
              {latency}
            </span>
          ) : null}
        </span>
        {tags.length > 0 || accelerator || latency ? (
          <span aria-hidden="true" className="flex flex-wrap items-baseline gap-x-2">
            {tags.length > 0 ? (
              <span className="flex flex-wrap gap-1">
                {tags.map((tag) => (
                  <span key={tag} data-tag translate="no" className="text-[10px] font-normal leading-none text-ovcs-muted">
                    {tag}
                  </span>
                ))}
              </span>
            ) : null}
            {accelerator ? (
              <span data-accelerator className={`text-[9px] leading-none ${FIGURE}`}>
                {accelerator}
              </span>
            ) : null}
            {latency ? (
              <span data-latency-note title="Not in the pipeline's total" className={`text-[9px] leading-none ${FIGURE}`}>
                latency
              </span>
            ) : null}
          </span>
        ) : null}
      </span>
      {group.status && style.dot ? <span aria-hidden="true" className={`ml-auto ${style.dot}`} /> : null}
      {unsaved > 0 ? (
        <OvcsBadge tone="warn" aria-hidden="true" className={`min-w-4 text-center tabular-nums ${group.status && style.dot ? '' : 'ml-auto'}`}>
          {unsaved}
        </OvcsBadge>
      ) : null}
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

/**
 * A pipeline's name, with the time one pair or frame takes it at the end of the row once the unit status reports it,
 * over what it shows.
 */
function Pipeline({ name, children }) {
  const totalMs = useStatus((state) => state.snapshot?.pipelines?.[name]?.totalMs)
  return (
    <div className="flex flex-col gap-1">
      <h3 className={`flex items-baseline gap-2 ${SUBSECTION_HEADING}`}>
        {title(name)}
        {totalMs == null ? null : (
          <>
            {' '}
            <span data-total className={`${FIGURE} ${TOTAL_INSET}`}>
              {milliseconds(totalMs)}
            </span>
          </>
        )}
      </h3>
      {children}
    </div>
  )
}

/**
 * A pipeline's steps as numbered boxes, one per line, with a bracket over the rows of each run of them computed in one
 * pass. The list and the brackets share the grid's rows.
 */
function Steps({ name, groups, selectedGroupId, box }) {
  return (
    <div className="grid" style={{ gridTemplateRows: `repeat(${groups.length}, auto)` }}>
      <RunBrackets name={name} steps={groups} />
      <ol aria-label={title(name)} className="col-start-1 row-span-full grid grid-rows-subgrid">
        {groups.map((group, index) => (
          <li key={group.id} className="grid grid-cols-[1.5rem_minmax(0,1fr)] items-center gap-2 py-0.5">
            <Step number={index + 1} first={index === 0} last={index === groups.length - 1} selected={group.id === selectedGroupId} />
            {box(group, groups)}
          </li>
        ))}
      </ol>
    </div>
  )
}

/**
 * The vision unit's pipelines as a menu, each a numbered flow of boxes that select their group. Detection is listed on
 * every unit, so the menu reads the same everywhere: on a unit whose only steps are the stereo pipeline's, as one greyed line.
 */
export default function Pipelines() {
  const { pipelines, selectedGroupId, box } = useGroupBoxes()
  if (pipelines.length === 0) return null
  // A camera of its own is a pipeline of one source, with no step.
  const withInference = pipelines.some(({ name, groups }) => name !== 'stereo' && groups.some((group) => group.role === 'step'))

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
