import { useId, useState } from 'react'
import { OvcsCard, OvcsStatus } from '@ovcs/ui/react'
import { diskName, droppedText, formatBytes, formatDuration } from './format.js'
import { recording as inProgress, useRecordings } from '../../stores/recordings.js'
import { useStatus } from '../../stores/status.js'
import { PRIMARY } from '../../styles.js'

const PRESETS = [
  {
    value: 'review',
    label: 'review',
    description: 'Compressed images, depth, detections and segmentation: hours of driving to look back on.'
  },
  {
    value: 'replay',
    label: 'replay',
    description: "Raw stereo images and each camera's images as they come: a drive to play again in ROS 2."
  }
]

const CLOCKS = [
  { value: 'automatic', label: 'automatic', description: "The board's clock once NTP has set it, the time since the start before." },
  { value: 'system', label: 'system', description: "The board's clock, the one ROS 2 on the network shares." },
  { value: 'since_start', label: 'since start', description: 'The time since the recording started, for a board whose clock is not set.' }
]

const clockText = (clock) => CLOCKS.find((choice) => choice.value === clock)?.label ?? clock ?? '–'

/** One radio button a choice, each with the line that says what it does. */
function Choice({ legend, name, choices, value, onChange, disabled }) {
  const id = useId()
  return (
    <fieldset className="flex min-w-0 flex-col gap-2" disabled={disabled}>
      <legend className="pb-1 text-xs text-ovcs-muted">{legend}</legend>
      {choices.map((choice) => (
        <div key={choice.value} className="flex items-start gap-2">
          <input
            type="radio"
            id={`${id}-${choice.value}`}
            name={`${id}-${name}`}
            value={choice.value}
            checked={value === choice.value}
            onChange={() => onChange(choice.value)}
            aria-describedby={`${id}-${choice.value}-description`}
            className="mt-1 size-4 shrink-0 accent-ovcs-accent"
          />
          <div className="flex min-w-0 flex-col">
            <label htmlFor={`${id}-${choice.value}`} className="font-medium">
              {choice.label}
            </label>
            <span id={`${id}-${choice.value}-description`} className="text-sm text-ovcs-muted">
              {choice.description}
            </span>
          </div>
        </div>
      ))}
    </fieldset>
  )
}

function Figure({ label, wide = false, children }) {
  return (
    <div className={`flex min-w-0 flex-col ${wide ? 'col-span-2' : ''}`}>
      <dt className="text-xs text-ovcs-muted">{label}</dt>
      <dd className="break-words font-semibold tabular-nums">{children}</dd>
    </div>
  )
}

/** What the recording in progress records, for how long, how much and on which disk. */
function Figures({ recording, disks }) {
  const disk = disks.find((listed) => listed.id === recording.disk)
  return (
    <dl className="grid grid-cols-2 gap-x-6 gap-y-2 sm:grid-cols-4">
      <div className="col-span-2 flex min-w-0 flex-col">
        <dt className="text-xs text-ovcs-muted">recording</dt>
        <dd className="break-all font-mono text-sm font-semibold">{recording.name}</dd>
      </div>
      <Figure label="preset">{recording.preset}</Figure>
      <Figure label="clock">{clockText(recording.clockInUse)}</Figure>
      <Figure label="duration">{formatDuration(recording.durationMs)}</Figure>
      <Figure label="size">{formatBytes(recording.bytes)}</Figure>
      <Figure label="disk">{disk ? diskName(disk) : (recording.disk ?? '–')}</Figure>
      <Figure label="dropped" wide>
        {droppedText(recording.dropped)}
      </Figure>
    </dl>
  )
}

/**
 * Starts a recording of the preset and on the clock chosen, or shows the one in progress with its live figures and
 * stops it; while idle, the bag exporter's warning, such as a recording that stopped for want of a disk.
 */
export default function Recorder({ headingId }) {
  const recording = useRecordings(inProgress)
  const disks = useRecordings((state) => state.disks)
  const busy = useRecordings((state) => state.busy)
  const start = useRecordings((state) => state.start)
  const stop = useRecordings((state) => state.stop)
  const status = useStatus((state) => state.snapshot?.exporters?.find((exporter) => exporter.id === 'ros2_bag')?.status)
  const [preset, setPreset] = useState('review')
  const [clock, setClock] = useState('automatic')

  return (
    <OvcsCard as="section" aria-labelledby={headingId} className="flex flex-col gap-4">
      <h3 id={headingId} className="font-semibold">
        Recorder
      </h3>
      {recording ? (
        <>
          <Figures recording={recording} disks={disks} />
          <div>
            <button type="button" disabled={busy !== null} onClick={() => stop(recording.id)} className={PRIMARY}>
              {busy === `stop:${recording.id}` ? 'Stopping…' : 'Stop'}
            </button>
          </div>
        </>
      ) : (
        <>
          <div className="grid gap-4 sm:grid-cols-2">
            <Choice legend="Preset" name="preset" choices={PRESETS} value={preset} onChange={setPreset} disabled={busy !== null} />
            <Choice legend="Clock" name="clock" choices={CLOCKS} value={clock} onChange={setClock} disabled={busy !== null} />
          </div>
          <div>
            <button type="button" disabled={busy !== null} onClick={() => start({ preset, clock })} className={PRIMARY}>
              {busy === 'start' ? 'Starting…' : 'Start'}
            </button>
          </div>
        </>
      )}
      {!recording && status && status.level !== 'ok' ? (
        <OvcsStatus tone="error" className="text-sm">
          {status.detail}
        </OvcsStatus>
      ) : null}
    </OvcsCard>
  )
}
