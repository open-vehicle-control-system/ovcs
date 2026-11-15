/** A count of bytes in decimal units, as disks are sold: `812 B`, `3.4 MB`, `12.1 GB`; `–` when unknown. */
export function formatBytes(bytes) {
  if (bytes == null) return '–'
  const [unit, size] = [
    ['GB', 1e9],
    ['MB', 1e6],
    ['kB', 1e3]
  ].find(([, size]) => bytes >= size) ?? ['B', 1]
  return unit === 'B' ? `${bytes} B` : `${(bytes / size).toFixed(1)} ${unit}`
}

/** A duration in milliseconds: `42 s`, `3 min 05 s`, `1 h 02 min`; `–` when unknown. */
export function formatDuration(ms) {
  if (ms == null) return '–'
  const seconds = Math.floor(ms / 1000)
  const [hours, minutes] = [Math.floor(seconds / 3600), Math.floor((seconds % 3600) / 60)]
  const pad = (number) => String(number).padStart(2, '0')
  if (hours > 0) return `${hours} h ${pad(minutes)} min`
  if (minutes > 0) return `${minutes} min ${pad(seconds % 60)} s`
  return `${seconds} s`
}

/** A time as the reader's locale writes a date and an hour; `–` when unknown. */
export const formatTime = (iso) =>
  iso == null ? '–' : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'medium' }).format(new Date(iso))

/** A disk's name: the unit's storage, its label, or its device for one without a filesystem. */
export const diskName = (disk) => (disk.internal ? "Unit's storage" : disk.label || disk.device || disk.id)

// A share in percent to one decimal, `< 0.1 %` for one that rounds to nothing.
const formatShare = (share) => (share < 0.0005 ? '< 0.1 %' : `${(share * 100).toFixed(1)} %`)

/**
 * The messages a recording dropped: `none`, or their count and their share of the messages that reached the recorder,
 * written or dropped, without it when the messages written are not known.
 */
export function droppedText(dropped, messages) {
  if (!dropped?.length) return 'none'
  const total = dropped.reduce((sum, { count }) => sum + count, 0)
  const count = `${total} ${total === 1 ? 'message' : 'messages'}`
  return messages == null ? count : `${count} · ${formatShare(total / (messages + total))}`
}

/** The topics that dropped messages, the most first, then by name. */
export const droppedByTopic = (dropped) =>
  [...dropped].sort((one, other) => other.count - one.count || one.topic.localeCompare(other.topic))
