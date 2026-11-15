import { useId, useState } from 'react'
import { OvcsButton, OvcsCard, OvcsDialog, OvcsStatus, OvcsSwitch } from '@ovcs/ui/react'
import { diskName, formatBytes } from './format.js'
import { useRecordings } from '../../stores/recordings.js'
import { SMALL_BUTTON } from '../../styles.js'

const TONES = { mounted: 'ok', ejecting: 'warn', ejected: 'muted', unplugged: 'muted', unusable: 'error', formatting: 'warn' }

const DEFAULT_LABEL = 'ovcs-recordings'

// The space used on a disk as a bar, with the free bytes in words; only the free bytes when its size is not known.
function Space({ disk, name }) {
  if (disk.freeBytes == null) return null
  if (disk.sizeBytes == null) return <span className="text-sm tabular-nums">{formatBytes(disk.freeBytes)} free</span>

  const used = Math.max(disk.sizeBytes - disk.freeBytes, 0)
  const text = `${formatBytes(disk.freeBytes)} free of ${formatBytes(disk.sizeBytes)}`
  return (
    <div className="flex min-w-0 flex-col gap-1">
      <div
        role="meter"
        aria-label={`Space used on ${name}`}
        aria-valuemin={0}
        aria-valuemax={disk.sizeBytes}
        aria-valuenow={used}
        aria-valuetext={text}
        className="h-2 w-full overflow-hidden rounded bg-ovcs-border"
      >
        <div className="h-full bg-ovcs-accent" style={{ width: `${(used / disk.sizeBytes) * 100}%` }} />
      </div>
      <span className="text-sm tabular-nums">{text}</span>
    </div>
  )
}

/** Asks for the label to give a disk before it is erased, and formats it. */
function FormatDialog({ disk, name, onClose, onFormat }) {
  const headingId = useId()
  const messageId = useId()
  const inputId = useId()
  const [label, setLabel] = useState(DEFAULT_LABEL)

  return (
    <OvcsDialog aria-labelledby={headingId} aria-describedby={messageId} onClose={onClose} align="center" className="max-w-md">
      <OvcsCard
        as="form"
        className="flex flex-col gap-3"
        onSubmit={(event) => {
          event.preventDefault()
          onFormat(disk.id, label)
        }}
      >
        <h2 id={headingId} className="font-semibold">
          Format {name}?
        </h2>
        <p id={messageId} className="text-sm text-ovcs-muted">
          Everything on {name} is erased. The unit makes it an f2fs disk with this label, then mounts it last in the order.
        </p>
        <div className="flex flex-col gap-1">
          <label htmlFor={inputId} className="text-xs text-ovcs-muted">
            Label
          </label>
          <input
            id={inputId}
            value={label}
            required
            onChange={(event) => setLabel(event.target.value)}
            className="min-h-9 rounded border border-ovcs-border bg-ovcs-surface px-2 text-sm"
          />
        </div>
        <div className="flex flex-wrap justify-end gap-2">
          <OvcsButton autoFocus onClick={onClose}>
            Cancel
          </OvcsButton>
          <OvcsButton type="submit" variant="danger">
            Format
          </OvcsButton>
        </div>
      </OvcsCard>
    </OvcsDialog>
  )
}

function Disk({ disk, last, busy, onFormat }) {
  const moveDisk = useRecordings((state) => state.moveDisk)
  const enableDisk = useRecordings((state) => state.enableDisk)
  const ejectDisk = useRecordings((state) => state.ejectDisk)
  const name = diskName(disk)
  const ordered = disk.position != null
  const idle = busy === null
  const formattable = !disk.internal && disk.device != null && ['unusable', 'ejected'].includes(disk.state)

  return (
    <li aria-label={name} className="flex flex-col gap-2 py-3 first:pt-0 last:pb-0">
      <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
          <span className="break-all font-semibold">{name}</span>
          <OvcsStatus tone={TONES[disk.state]} className="text-sm">
            {disk.state}
          </OvcsStatus>
        </div>
        {ordered ? (
          <div className="flex items-center gap-1.5">
            <button
              type="button"
              disabled={!idle || disk.position === 0}
              aria-label={`Move ${name} up`}
              onClick={() => moveDisk(disk.id, disk.position - 1)}
              className={SMALL_BUTTON}
            >
              <span aria-hidden="true">↑</span>
            </button>
            <button
              type="button"
              disabled={!idle || last}
              aria-label={`Move ${name} down`}
              onClick={() => moveDisk(disk.id, disk.position + 1)}
              className={SMALL_BUTTON}
            >
              <span aria-hidden="true">↓</span>
            </button>
            <OvcsSwitch
              checked={disk.enabled}
              disabled={!idle}
              label={`Record on ${name}`}
              onClick={() => enableDisk(disk.id, !disk.enabled)}
              className="ml-1.5"
            />
          </div>
        ) : null}
      </div>
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-sm text-ovcs-muted">
        {disk.filesystem ? <span>{disk.filesystem}</span> : null}
        {disk.device && disk.device !== name ? <span className="font-mono text-xs leading-5">{disk.device}</span> : null}
        {ordered && !disk.enabled ? <span>turned off: recordings skip it</span> : null}
      </div>
      <Space disk={disk} name={name} />
      {disk.problem ? <p className="text-sm text-ovcs-error-text">{disk.problem}</p> : null}
      {(!disk.internal && disk.state === 'mounted') || formattable ? (
        <div className="flex flex-wrap gap-1.5">
          {!disk.internal && disk.state === 'mounted' ? (
            <button type="button" disabled={!idle} aria-label={`Eject ${name}`} onClick={() => ejectDisk(disk.id)} className={SMALL_BUTTON}>
              {busy === `eject:${disk.id}` ? 'Ejecting…' : 'Eject'}
            </button>
          ) : null}
          {formattable ? (
            <button
              type="button"
              disabled={!idle}
              aria-label={`Format ${name}`}
              onClick={() => onFormat(disk)}
              className={`${SMALL_BUTTON} text-ovcs-error-text`}
            >
              {busy === `format:${disk.id}` ? 'Formatting…' : 'Format'}
            </button>
          ) : null}
        </div>
      ) : null}
    </li>
  )
}

/**
 * The disks in the order recordings fill them, then those the unit cannot use: each moved up or down, turned on or
 * off, ejected before it is pulled out, or formatted once confirmed when it has no filesystem the unit mounts.
 */
export default function DiskList({ headingId }) {
  const disks = useRecordings((state) => state.disks)
  const busy = useRecordings((state) => state.busy)
  const formatDisk = useRecordings((state) => state.formatDisk)
  const [formatting, setFormatting] = useState(null)
  const lastPosition = Math.max(-1, ...disks.filter((disk) => disk.position != null).map((disk) => disk.position))

  return (
    <OvcsCard as="section" aria-labelledby={headingId} className="flex flex-col gap-3">
      <h3 id={headingId} className="font-semibold">
        Disks
      </h3>
      <p className="text-sm text-ovcs-muted">
        A recording goes on the first disk that is mounted, turned on and has room, then on to the next one.
      </p>
      <ol className="divide-y divide-ovcs-border">
        {disks.map((disk) => (
          <Disk
            key={disk.id}
            disk={disk}
            last={disk.position === lastPosition}
            busy={busy}
            onFormat={setFormatting}
          />
        ))}
      </ol>
      {formatting ? (
        <FormatDialog
          disk={formatting}
          name={diskName(formatting)}
          onClose={() => setFormatting(null)}
          onFormat={(id, label) => {
            setFormatting(null)
            formatDisk(id, label)
          }}
        />
      ) : null}
    </OvcsCard>
  )
}
