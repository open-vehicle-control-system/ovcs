import { useId, useState, useSyncExternalStore } from 'react'
import { OvcsCard, OvcsStatus, useOvcsConfirm } from '@ovcs/ui/react'
import { DroppedByTopic, DroppedToggle } from './Dropped.jsx'
import { disksText, formatBytes, formatDuration, formatShortTime, formatTime } from './format.js'
import { recordingDownloadUrl } from '../../services/recordings.js'
import { useRecordings } from '../../stores/recordings.js'
import { SMALL_BUTTON } from '../../styles.js'

const MD = '(min-width: 768px)'

const DANGER_BUTTON = `${SMALL_BUTTON} text-ovcs-error-text`

// Whether the screen is at least `md` wide; without `matchMedia`, as in tests, it is.
const subscribeToWidth = (onChange) => {
  const query = window.matchMedia?.(MD)
  query?.addEventListener('change', onChange)
  return () => query?.removeEventListener('change', onChange)
}
const wideScreen = () => window.matchMedia?.(MD).matches ?? true

function Started({ at }) {
  return (
    <time dateTime={at ?? undefined} title={formatTime(at)}>
      {formatShortTime(at)}
    </time>
  )
}

// A recording's name, `<start>_<preset>`, which may wrap before its preset.
const breakable = (name) => {
  const [start, ...rest] = name.split('_')
  return rest.length ? (
    <>
      {start}
      <wbr />_{rest.join('_')}
    </>
  ) : (
    name
  )
}

function NameAndState({ recording }) {
  return (
    <span className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5">
      <span translate="no" className="break-words font-mono text-xs font-semibold leading-5">
        {breakable(recording.name)}
      </span>
      {recording.state === 'recording' ? (
        <OvcsStatus tone="ok" className="text-xs">
          recording
        </OvcsStatus>
      ) : null}
    </span>
  )
}

/** Download and Delete, for a recording no longer in progress. */
function Actions({ recording, busy, onDelete }) {
  if (recording.state === 'recording') return null
  return (
    <span className="inline-flex gap-1.5">
      <a
        href={recordingDownloadUrl(recording.id)}
        download={`${recording.name}.tar`}
        aria-label={`Download ${recording.name}`}
        className={`${SMALL_BUTTON} inline-flex items-center`}
      >
        Download
      </a>
      <button
        type="button"
        disabled={busy !== null}
        aria-label={`Delete ${recording.name}`}
        onClick={() => onDelete(recording)}
        className={DANGER_BUTTON}
      >
        {busy === `delete:${recording.id}` ? 'Deleting…' : 'Delete'}
      </button>
    </span>
  )
}

const CELL = 'py-2 pr-3 align-middle'
const NUMBER = `${CELL} whitespace-nowrap text-right tabular-nums`

/** A recording as a row of the table, with its drops by topic in a row under it once opened. */
function Row({ recording, disks, busy, onDelete }) {
  const droppedId = useId()
  const [open, setOpen] = useState(false)
  return (
    <>
      <tr aria-label={recording.name} className="border-t border-ovcs-border">
        <td className={CELL}>
          <NameAndState recording={recording} />
        </td>
        <td className={`${CELL} tabular-nums`}>
          <Started at={recording.startedAt} />
        </td>
        <td className={NUMBER}>{formatDuration(recording.durationMs)}</td>
        <td className={NUMBER}>{formatBytes(recording.bytes)}</td>
        <td className={`${CELL} text-ovcs-muted`}>{disksText(recording.parts, disks)}</td>
        <td className={`${CELL} whitespace-nowrap`}>
          <DroppedToggle
            dropped={recording.dropped}
            messages={recording.messages}
            open={open}
            onToggle={() => setOpen(!open)}
            controls={droppedId}
          />
        </td>
        <td className="whitespace-nowrap py-2 text-right align-middle">
          <Actions recording={recording} busy={busy} onDelete={onDelete} />
        </td>
      </tr>
      {recording.dropped?.length ? (
        <tr hidden={!open}>
          <td colSpan={7} className="pb-3 pl-4">
            <DroppedByTopic id={droppedId} dropped={recording.dropped} open={open} />
          </td>
        </tr>
      ) : null}
    </>
  )
}

const HEADER = 'pb-2 pr-3 font-medium'

function RecordingTable({ recordings, disks, busy, onDelete }) {
  return (
    <table aria-label="Recordings" className="w-full text-left text-sm">
      <thead className="text-xs text-ovcs-muted">
        <tr>
          <th scope="col" className={HEADER}>
            Name
          </th>
          <th scope="col" className={HEADER}>
            Started
          </th>
          <th scope="col" className={`${HEADER} text-right`}>
            Duration
          </th>
          <th scope="col" className={`${HEADER} text-right`}>
            Size
          </th>
          <th scope="col" className={HEADER}>
            Disks
          </th>
          <th scope="col" className={HEADER}>
            Dropped
          </th>
          <th scope="col" className="pb-2 font-medium">
            <span className="sr-only">Actions</span>
          </th>
        </tr>
      </thead>
      <tbody>
        {recordings.map((recording) => (
          <Row key={recording.id} recording={recording} disks={disks} busy={busy} onDelete={onDelete} />
        ))}
      </tbody>
    </table>
  )
}

/** A recording as a card, for a narrow screen: its name, its facts on one line, its drops, and its actions. */
function Card({ recording, disks, busy, onDelete }) {
  const droppedId = useId()
  const [open, setOpen] = useState(false)
  const facts = [formatShortTime(recording.startedAt), formatDuration(recording.durationMs), formatBytes(recording.bytes), disksText(recording.parts, disks)]
  return (
    <li aria-label={recording.name} className="flex flex-col gap-1.5 py-3 first:pt-0 last:pb-0">
      <NameAndState recording={recording} />
      <p className="text-sm tabular-nums text-ovcs-muted">{facts.join(' · ')}</p>
      {recording.dropped?.length ? (
        <div className="flex flex-col gap-1 text-sm">
          <span className="flex items-center gap-2">
            <span className="text-xs text-ovcs-muted">dropped</span>
            <DroppedToggle
              dropped={recording.dropped}
              messages={recording.messages}
              open={open}
              onToggle={() => setOpen(!open)}
              controls={droppedId}
            />
          </span>
          <DroppedByTopic id={droppedId} dropped={recording.dropped} open={open} />
        </div>
      ) : null}
      {recording.state === 'recording' ? null : (
        <div className="pt-0.5">
          <Actions recording={recording} busy={busy} onDelete={onDelete} />
        </div>
      )}
    </li>
  )
}

/**
 * The recordings, the newest first: a table of their facts, parts' disks and drops on a wide screen, a list of cards on
 * a narrow one; each downloaded as one tar or deleted once confirmed.
 */
export default function RecordingList({ headingId }) {
  const recordings = useRecordings((state) => state.recordings)
  const disks = useRecordings((state) => state.disks)
  const loaded = useRecordings((state) => state.loaded)
  const busy = useRecordings((state) => state.busy)
  const remove = useRecordings((state) => state.remove)
  const wide = useSyncExternalStore(subscribeToWidth, wideScreen)
  const [confirm, confirmation] = useOvcsConfirm()

  const askToDelete = async (recording) => {
    const parts = recording.parts.length
    const confirmed = await confirm({
      title: `Delete ${recording.name}?`,
      message:
        parts > 1
          ? `Its ${parts} parts are deleted from their disks. This cannot be undone.`
          : 'It is deleted from its disk. This cannot be undone.',
      confirmLabel: 'Delete',
      danger: true
    })
    if (confirmed) remove(recording.id)
  }

  return (
    <OvcsCard as="section" aria-labelledby={headingId} className="flex flex-col gap-3">
      <h3 id={headingId} className="font-semibold">
        Recordings
      </h3>
      {loaded && recordings.length === 0 ? <p className="text-sm text-ovcs-muted">No recording on the disks plugged in.</p> : null}
      {recordings.length > 0 && wide ? (
        <RecordingTable recordings={recordings} disks={disks} busy={busy} onDelete={askToDelete} />
      ) : null}
      {recordings.length > 0 && !wide ? (
        <ul className="divide-y divide-ovcs-border">
          {recordings.map((recording) => (
            <Card key={recording.id} recording={recording} disks={disks} busy={busy} onDelete={askToDelete} />
          ))}
        </ul>
      ) : null}
      {confirmation}
    </OvcsCard>
  )
}
