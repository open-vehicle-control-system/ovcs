import { OvcsBadge, OvcsCard, OvcsStatus, useOvcsConfirm } from '@ovcs/ui/react'
import { diskName, droppedText, formatBytes, formatDuration, formatTime } from './format.js'
import { recordingDownloadUrl } from '../../services/recordings.js'
import { useRecordings } from '../../stores/recordings.js'
import { SMALL_BUTTON } from '../../styles.js'

const DANGER_BUTTON = `${SMALL_BUTTON} text-ovcs-error-text`

// Each part's number and the disk it is on.
const partsText = (parts, disks) =>
  parts
    .map((part) => {
      const disk = disks.find((listed) => listed.id === part.disk)
      return `${part.number} on ${disk ? diskName(disk) : part.disk}`
    })
    .join(', ')

function Fact({ label, wide = false, children }) {
  return (
    <div className={`flex min-w-0 flex-col ${wide ? 'col-span-2' : ''}`}>
      <dt className="text-xs text-ovcs-muted">{label}</dt>
      <dd className="break-words tabular-nums">{children}</dd>
    </div>
  )
}

function Recording({ recording, disks, busy, onDelete }) {
  const inProgress = recording.state === 'recording'
  return (
    <li aria-label={recording.name} className="flex flex-col gap-2 py-3 first:pt-0 last:pb-0">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
        <span className="break-all font-mono text-sm font-semibold">{recording.name}</span>
        {recording.preset ? <OvcsBadge>{recording.preset}</OvcsBadge> : null}
        {inProgress ? <OvcsStatus tone="ok" className="text-sm">recording</OvcsStatus> : null}
      </div>
      <dl className="grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-4">
        <Fact label="started">{formatTime(recording.startedAt)}</Fact>
        <Fact label="duration">{formatDuration(recording.durationMs)}</Fact>
        <Fact label="size">{formatBytes(recording.bytes)}</Fact>
        <Fact label={recording.parts.length > 1 ? 'parts' : 'part'} wide>
          {partsText(recording.parts, disks) || '–'}
        </Fact>
        <Fact label="dropped" wide>
          {droppedText(recording.dropped)}
        </Fact>
      </dl>
      {inProgress ? null : (
        <div className="flex flex-wrap gap-1.5">
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
        </div>
      )}
    </li>
  )
}

/** The recordings, the newest first: their facts, parts and disks, each downloaded as one tar or deleted once confirmed. */
export default function RecordingList({ headingId }) {
  const recordings = useRecordings((state) => state.recordings)
  const disks = useRecordings((state) => state.disks)
  const loaded = useRecordings((state) => state.loaded)
  const busy = useRecordings((state) => state.busy)
  const remove = useRecordings((state) => state.remove)
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
      <ul className="divide-y divide-ovcs-border">
        {recordings.map((recording) => (
          <Recording key={recording.id} recording={recording} disks={disks} busy={busy} onDelete={askToDelete} />
        ))}
      </ul>
      {confirmation}
    </OvcsCard>
  )
}
