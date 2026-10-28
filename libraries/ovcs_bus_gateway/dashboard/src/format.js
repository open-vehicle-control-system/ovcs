export const LIVE_MS = 2000

export function duration(ms) {
  const seconds = Math.floor(ms / 1000)
  if (seconds < 1) return 'now'
  if (seconds < 60) return `${seconds} s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h`
  return `${Math.floor(seconds / 86400)} d`
}

export function ago(ms) {
  const span = duration(ms)
  return span === 'now' ? 'just now' : `${span} ago`
}

export function formatValue(value) {
  if (value === true) return { text: 'true', tone: 'ok' }
  if (value === false) return { text: 'false', tone: 'muted' }
  if (value === null || value === undefined) return { text: '—', tone: 'muted' }
  if (typeof value === 'object') return { text: JSON.stringify(value), tone: 'plain' }
  return { text: String(value), tone: 'plain' }
}

export const isLive = (signal, now) => signal.changeSeenAt !== null && now - signal.changeSeenAt < LIVE_MS
