import { useId, useRef, useState } from 'react'
import { OvcsBadge, OvcsButton, OvcsCard, OvcsDialog, OvcsStatus, OvcsSwitch, focusClass as FOCUS } from '@ovcs/ui/react'
import Hint from '../Hint.jsx'
import { FREE_FLOOR_BYTES, nextDisk } from './disks.js'
import { diskName, formatBytes } from './format.js'
import { useRecordings } from '../../stores/recordings.js'
import { SMALL_BUTTON } from '../../styles.js'

const TONES = { mounted: 'ok', ejecting: 'warn', ejected: 'muted', unplugged: 'muted', unusable: 'error', formatting: 'warn' }

const DEFAULT_LABEL = 'ovcs-recordings'

const FILL_ORDER = {
  title: 'Fill order',
  text: `A recording goes on the first disk in this order that is mounted, turned on and has ${formatBytes(FREE_FLOOR_BYTES)} free. When that disk fills, is ejected or pulled out, it goes on on the next one.`
}

const ICON_BUTTON = `inline-flex size-7 items-center justify-center rounded border border-ovcs-border text-ovcs-muted enabled:hover:border-ovcs-accent enabled:hover:text-ovcs-text disabled:cursor-not-allowed disabled:opacity-40 ${FOCUS}`

const ARROWS = { up: 'M8 3.5 12.5 9h-9Z', down: 'M8 12.5 3.5 7h9Z' }

function Arrow({ direction }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" fill="currentColor" className="size-3.5">
      <path d={ARROWS[direction]} />
    </svg>
  )
}

// The free bytes in words, of the size when it is known; `null` when the free bytes are not known.
const spaceText = (disk) => {
  if (disk.freeBytes == null) return null
  return disk.sizeBytes == null ? `${formatBytes(disk.freeBytes)} free` : `${formatBytes(disk.freeBytes)} free of ${formatBytes(disk.sizeBytes)}`
}

/** The space used on a disk of known size as a thin bar, in the error colour once under the free floor. */
function UsageBar({ disk, name }) {
  if (disk.freeBytes == null || disk.sizeBytes == null) return null
  const used = Math.max(disk.sizeBytes - disk.freeBytes, 0)
  return (
    <div
      role="meter"
      aria-label={`Space used on ${name}`}
      aria-valuemin={0}
      aria-valuemax={disk.sizeBytes}
      aria-valuenow={used}
      aria-valuetext={spaceText(disk)}
      className="h-1.5 w-full overflow-hidden rounded-full bg-ovcs-border"
    >
      <div
        className={`h-full rounded-full ${disk.freeBytes < FREE_FLOOR_BYTES ? 'bg-ovcs-error' : 'bg-ovcs-accent'}`}
        style={{ width: `${(used / disk.sizeBytes) * 100}%` }}
      />
    </div>
  )
}

/** Asks for the label to give a disk before it is erased, and formats it. */
function FormatDialog({ disk, name, returnFocus, onClose, onFormat }) {
  const headingId = useId()
  const messageId = useId()
  const inputId = useId()
  const [label, setLabel] = useState(DEFAULT_LABEL)

  return (
    <OvcsDialog
      aria-labelledby={headingId}
      aria-describedby={messageId}
      onClose={onClose}
      returnFocus={returnFocus}
      align="center"
      className="max-w-md"
    >
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

// The state a disk shows: the action under way on it before the unit lists it so.
const shownState = (disk, busy) => {
  if (busy === `eject:${disk.id}`) return 'ejecting'
  if (busy === `format:${disk.id}`) return 'formatting'
  return disk.state
}

// Why recordings skip a disk in the order that the unit lists as mounted.
const skipped = (disk) => {
  if (!disk.enabled) return 'off: recordings skip it'
  if (disk.state === 'mounted' && disk.freeBytes != null && disk.freeBytes < FREE_FLOOR_BYTES) {
    return `under ${formatBytes(FREE_FLOOR_BYTES)} free: recordings skip it`
  }
  return null
}

function Disk({ disk, last, busy, marker }) {
  const moveDisk = useRecordings((state) => state.moveDisk)
  const enableDisk = useRecordings((state) => state.enableDisk)
  const ejectDisk = useRecordings((state) => state.ejectDisk)
  const formatDisk = useRecordings((state) => state.formatDisk)
  const formatButton = useRef(null)
  const [formatting, setFormatting] = useState(false)
  const name = diskName(disk)
  const ordered = disk.position != null
  const idle = busy === null
  const state = shownState(disk, busy)
  const details = [disk.filesystem, disk.device && disk.device !== name ? disk.device : null].filter(Boolean).join(' · ')
  const skip = ordered ? skipped(disk) : null

  const ejectable = !disk.internal && disk.state === 'mounted'
  const formattable = !disk.internal && disk.device != null && ['unusable', 'ejected'].includes(disk.state)

  return (
    <li aria-label={name} className="flex gap-3 py-3 first:pt-0 last:pb-0">
      <span
        aria-hidden="true"
        className={`mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full border-2 text-xs font-semibold tabular-nums ${
          marker ? 'border-ovcs-accent text-ovcs-accent-text' : 'border-ovcs-border text-ovcs-muted'
        } ${ordered ? '' : 'invisible'}`}
      >
        {ordered ? disk.position + 1 : null}
      </span>
      <div className="flex min-w-0 flex-1 flex-col gap-1.5">
        <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1.5">
          <div className="flex min-h-7 min-w-32 flex-1 flex-wrap items-center gap-x-2 gap-y-0.5">
            <span className={`break-words font-semibold ${skip ? 'text-ovcs-muted' : ''}`}>{name}</span>
            {marker ? <OvcsBadge>{marker}</OvcsBadge> : null}
          </div>
          <div className="ml-auto flex shrink-0 items-center gap-1">
            {ordered ? (
              <>
                <button
                  type="button"
                  disabled={!idle || disk.position === 0}
                  aria-label={`Move ${name} up`}
                  onClick={() => moveDisk(disk.id, disk.position - 1)}
                  className={ICON_BUTTON}
                >
                  <Arrow direction="up" />
                </button>
                <button
                  type="button"
                  disabled={!idle || last}
                  aria-label={`Move ${name} down`}
                  onClick={() => moveDisk(disk.id, disk.position + 1)}
                  className={ICON_BUTTON}
                >
                  <Arrow direction="down" />
                </button>
                <OvcsSwitch
                  checked={disk.enabled}
                  disabled={!idle}
                  label={`Record on ${name}`}
                  onClick={() => enableDisk(disk.id, !disk.enabled)}
                  className="mx-1.5"
                />
              </>
            ) : null}
            <span className="flex min-w-[5.5rem] justify-end gap-1">
              {ejectable ? (
                <button type="button" disabled={!idle} aria-label={`Eject ${name}`} onClick={() => ejectDisk(disk.id)} className={SMALL_BUTTON}>
                  {busy === `eject:${disk.id}` ? 'Ejecting…' : 'Eject'}
                </button>
              ) : null}
              {formattable ? (
                <button
                  ref={formatButton}
                  type="button"
                  disabled={!idle}
                  aria-label={`Format ${name}`}
                  onClick={() => setFormatting(true)}
                  className={`${SMALL_BUTTON} text-ovcs-error-text`}
                >
                  {busy === `format:${disk.id}` ? 'Formatting…' : 'Format…'}
                </button>
              ) : null}
            </span>
          </div>
        </div>
        <UsageBar disk={disk} name={name} />
        <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5 text-xs">
          <span className="flex flex-wrap items-baseline gap-x-3">
            <OvcsStatus tone={TONES[state]}>{state}</OvcsStatus>
            {spaceText(disk) ? <span className="tabular-nums text-ovcs-muted">{spaceText(disk)}</span> : null}
          </span>
          {details ? <span className="text-ovcs-muted">{details}</span> : null}
        </div>
        {skip ? <p className="text-xs text-ovcs-muted">{skip}</p> : null}
        {disk.problem ? <p className="text-xs text-ovcs-error-text">{disk.problem}</p> : null}
      </div>
      {formatting ? (
        <FormatDialog
          disk={disk}
          name={name}
          returnFocus={formatButton}
          onClose={() => setFormatting(false)}
          onFormat={(id, label) => {
            setFormatting(false)
            formatDisk(id, label)
          }}
        />
      ) : null}
    </li>
  )
}

/**
 * The disks in the order recordings fill them, then those the unit cannot use, the one `recording` is on or the one a
 * new recording takes marked: each moved up or down, turned on or off, ejected before it is pulled out, or formatted
 * once confirmed when it has no filesystem the unit mounts.
 */
export default function DiskList({ recording }) {
  const headingId = useId()
  const disks = useRecordings((state) => state.disks)
  const loaded = useRecordings((state) => state.loaded)
  const busy = useRecordings((state) => state.busy)
  const lastPosition = Math.max(-1, ...disks.filter((disk) => disk.position != null).map((disk) => disk.position))
  const marked = recording ? { id: recording.disk, marker: 'recording' } : { id: nextDisk(disks)?.id, marker: 'next' }

  return (
    <section
      aria-labelledby={headingId}
      className="flex min-w-0 flex-col gap-3 border-t border-ovcs-border pt-4 xl:border-l xl:border-t-0 xl:pl-8 xl:pt-0"
    >
      <div className="flex items-center gap-1.5">
        <h3 id={headingId} className="font-semibold">
          Disks
        </h3>
        <Hint hint={FILL_ORDER} />
      </div>
      {loaded && disks.length === 0 ? <p className="text-sm text-ovcs-muted">No disk found.</p> : null}
      <ol className="divide-y divide-ovcs-border">
        {disks.map((disk) => (
          <Disk
            key={disk.id}
            disk={disk}
            last={disk.position === lastPosition}
            busy={busy}
            marker={disk.id === marked.id ? marked.marker : null}
          />
        ))}
      </ol>
    </section>
  )
}
