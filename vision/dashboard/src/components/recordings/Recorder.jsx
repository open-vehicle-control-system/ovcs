import { useId, useState } from 'react'
import { OvcsCard, OvcsStatus, focusClass as FOCUS } from '@ovcs/ui/react'
import DiskList from './DiskList.jsx'
import { DroppedByTopic, DroppedSummary } from './Dropped.jsx'
import { FREE_FLOOR_BYTES, nextDisk, timeLeftMs, writeRate } from './disks.js'
import { diskName, formatBytes, formatDuration, formatRate } from './format.js'
import { recording as inProgress, useRecordings } from '../../stores/recordings.js'
import { useStatus } from '../../stores/status.js'
import { PRIMARY } from '../../styles.js'

const PRESETS = [
  { value: 'review', description: 'Compressed images, depth, detections' },
  { value: 'replay', description: 'Raw stereo and camera frames' }
]

const CLOCKS = [
  { value: 'automatic', label: 'automatic', description: "The board's clock once NTP has set it, the time since the start before." },
  { value: 'system', label: 'system', description: "The board's clock, the one ROS 2 on the network shares." },
  { value: 'since_start', label: 'since start', description: 'The time since the recording started, for a board whose clock is not set.' }
]

const CLOCKS_IN_USE = { system: 'system clock', since_start: 'time since start' }

/** The presets as two cards, one a radio button with its name and what it records. */
function PresetChoice({ value, onChange }) {
  const id = useId()
  return (
    <fieldset className="flex min-w-0 flex-col">
      <legend className="pb-1.5 text-xs text-ovcs-muted">Preset</legend>
      <div className="grid gap-2 sm:grid-cols-2">
        {PRESETS.map((preset) => (
          <label
            key={preset.value}
            className="flex cursor-pointer items-start gap-2.5 rounded border border-ovcs-border px-3 py-2.5 hover:border-ovcs-accent has-[:checked]:border-ovcs-accent has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-50 has-[:checked]:bg-[color-mix(in_srgb,var(--ovcs-accent)_12%,var(--ovcs-surface))]"
          >
            <input
              type="radio"
              name={`${id}-preset`}
              value={preset.value}
              checked={value === preset.value}
              onChange={() => onChange(preset.value)}
              aria-labelledby={`${id}-${preset.value}`}
              aria-describedby={`${id}-${preset.value}-description`}
              className={`mt-0.5 size-4 shrink-0 accent-ovcs-accent ${FOCUS}`}
            />
            <span className="flex min-w-0 flex-col gap-0.5">
              <span id={`${id}-${preset.value}`} className="font-medium leading-5">
                {preset.value}
              </span>
              <span id={`${id}-${preset.value}-description`} className="text-sm leading-snug text-ovcs-muted">
                {preset.description}
              </span>
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  )
}

/** The clocks as one segmented control, with the chosen one's explanation under it. */
function ClockChoice({ value, onChange }) {
  const id = useId()
  return (
    <fieldset className="flex min-w-0 flex-col">
      <legend className="pb-1.5 text-xs text-ovcs-muted">Clock</legend>
      <div className="inline-flex max-w-full self-start rounded border border-ovcs-border p-0.5">
        {CLOCKS.map((clock) => (
          <label
            key={clock.value}
            className="inline-flex min-h-8 cursor-pointer items-center whitespace-nowrap rounded-sm px-3 text-sm text-ovcs-muted hover:text-ovcs-text has-[:checked]:font-medium has-[:checked]:text-ovcs-accent-text has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-50 has-[:focus-visible]:outline has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-ovcs-accent has-[:checked]:bg-[color-mix(in_srgb,var(--ovcs-accent)_12%,var(--ovcs-surface))]"
          >
            <input
              type="radio"
              name={`${id}-clock`}
              value={clock.value}
              checked={value === clock.value}
              onChange={() => onChange(clock.value)}
              aria-describedby={`${id}-${clock.value}`}
              className="sr-only"
            />
            {clock.label}
          </label>
        ))}
      </div>
      {CLOCKS.map((clock) => (
        <p
          key={clock.value}
          id={`${id}-${clock.value}`}
          data-explanation
          hidden={value !== clock.value}
          className="mt-1.5 text-sm text-ovcs-muted"
        >
          {clock.description}
        </p>
      ))}
    </fieldset>
  )
}

/** Where a recording started now goes: the first disk that takes it, with its room, or why none does. */
function Destination({ id, disk }) {
  if (!disk) {
    return (
      <p id={id} className="text-sm text-ovcs-warn-text">
        No disk to record on: none is mounted, turned on and with {formatBytes(FREE_FLOOR_BYTES)} free.
      </p>
    )
  }
  return (
    <p id={id} className="text-sm text-ovcs-muted">
      on <span className="font-medium text-ovcs-text">{diskName(disk)}</span> · <span className="tabular-nums">{formatBytes(disk.freeBytes)}</span> free
    </p>
  )
}

/** The preset and clock to record with, and Start, beside the disk the recording goes on. */
function NewRecording() {
  const destinationId = useId()
  const disks = useRecordings((state) => state.disks)
  const loaded = useRecordings((state) => state.loaded)
  const busy = useRecordings((state) => state.busy)
  const start = useRecordings((state) => state.start)
  const status = useStatus((state) => state.snapshot?.exporters?.find((exporter) => exporter.id === 'ros2_bag')?.status)
  const [preset, setPreset] = useState('review')
  const [clock, setClock] = useState('automatic')
  const disk = nextDisk(disks)

  return (
    <div className="flex min-w-0 flex-col gap-4">
      <h3 className="font-semibold">New recording</h3>
      <fieldset disabled={busy !== null} className="flex min-w-0 flex-col gap-4">
        <PresetChoice value={preset} onChange={setPreset} />
        <ClockChoice value={clock} onChange={setClock} />
      </fieldset>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
        <button
          type="button"
          disabled={busy !== null || !loaded || !disk}
          aria-describedby={loaded ? destinationId : undefined}
          onClick={() => start({ preset, clock })}
          className={`${PRIMARY} px-5`}
        >
          {busy === 'start' ? 'Starting…' : 'Start'}
        </button>
        {loaded ? <Destination id={destinationId} disk={disk} /> : null}
      </div>
      {status && status.level !== 'ok' ? (
        <OvcsStatus tone="error" className="text-sm">
          {status.detail}
        </OvcsStatus>
      ) : null}
    </div>
  )
}

function Figure({ label, children }) {
  return (
    <div className="flex min-w-0 flex-col">
      <dt className="text-xs text-ovcs-muted">{label}</dt>
      <dd className="font-semibold tabular-nums">{children}</dd>
    </div>
  )
}

/** The recording in progress: its name, clock and disk, with Stop, then its live figures and its drops by topic. */
function LiveRecording({ recording }) {
  const droppedId = useId()
  const [open, setOpen] = useState(false)
  const disks = useRecordings((state) => state.disks)
  const busy = useRecordings((state) => state.busy)
  const stop = useRecordings((state) => state.stop)
  const disk = disks.find((listed) => listed.id === recording.disk)
  const rate = writeRate(recording)
  const left = timeLeftMs(disk?.freeBytes, rate)
  const facts = [
    CLOCKS_IN_USE[recording.clockInUse] ?? recording.clockInUse,
    recording.disk && `on ${disk ? diskName(disk) : recording.disk}`
  ]

  return (
    <div className="flex min-w-0 flex-col gap-4">
      <div className="flex items-start justify-between gap-4">
        <div className="flex min-w-0 flex-col gap-1">
          <div className="flex items-center gap-2">
            <h3 className="font-semibold">Recording</h3>
            <span aria-hidden="true" className="ovcs-status ovcs-status--ok motion-safe:animate-pulse" />
          </div>
          <p translate="no" className="break-all font-mono text-sm font-semibold">
            {recording.name}
          </p>
          <p className="text-sm text-ovcs-muted">{facts.filter(Boolean).join(' · ')}</p>
        </div>
        <button type="button" disabled={busy !== null} onClick={() => stop(recording.id)} className={`${PRIMARY} shrink-0 px-5`}>
          {busy === `stop:${recording.id}` ? 'Stopping…' : 'Stop'}
        </button>
      </div>
      <dl className="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4">
        <Figure label="duration">{formatDuration(recording.durationMs)}</Figure>
        <Figure label="size">{formatBytes(recording.bytes)}</Figure>
        <Figure label="write rate">{formatRate(rate)}</Figure>
        <Figure label="left on disk">{left == null ? '–' : `≈ ${formatDuration(left)}`}</Figure>
        <div className="col-span-2 flex min-w-0 flex-col sm:col-span-4">
          <dt className="text-xs text-ovcs-muted">dropped</dt>
          <dd className="font-semibold tabular-nums">
            <DroppedSummary
              dropped={recording.dropped}
              messages={recording.messages}
              open={open}
              onToggle={() => setOpen(!open)}
              controls={droppedId}
            />
          </dd>
        </div>
      </dl>
      {recording.dropped?.length ? <DroppedByTopic id={droppedId} dropped={recording.dropped} open={open} /> : null}
    </div>
  )
}

/**
 * The recorder: a new recording's preset and clock with Start, or the recording in progress with its live figures and
 * Stop, beside the disks recordings go on.
 */
export default function Recorder() {
  const recording = useRecordings(inProgress)

  return (
    <OvcsCard as="section" aria-label="Recorder" className="grid gap-x-8 gap-y-5 xl:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
      {recording ? <LiveRecording recording={recording} /> : <NewRecording />}
      <DiskList recording={recording} />
    </OvcsCard>
  )
}
