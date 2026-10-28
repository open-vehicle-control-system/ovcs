export const keyOf = ({ node, source, name }) => `${node}/${source}/${name}`

// The collector's per-node presence signal, shown as the node's status rather than as a row.
export const PRESENCE_SOURCE = 'OvcsBusGateway.Collector'
export const isPresence = (signal) => signal.source === PRESENCE_SOURCE && signal.name === 'connected'

// A signal from a forwarder that does not report publish times has a null `published_at`.
const publishedAt = (signal) => signal.published_at ?? signal.changed_at

// Returns a new Map. A snapshot replaces the state; an update merges more recently published
// signals into it. `changeSeenAt` is the browser time of the last update changing the value,
// null when none did since the snapshot.
export function applyFrame(state, frame, receivedAt = Date.now()) {
  if (frame.type === 'snapshot') {
    return new Map(frame.signals.map((signal) => [keyOf(signal), { ...signal, changeSeenAt: null }]))
  }

  if (frame.type === 'update') {
    const next = new Map(state)
    for (const signal of frame.signals) {
      const key = keyOf(signal)
      const stored = next.get(key)
      if (stored && publishedAt(signal) < publishedAt(stored)) continue
      const changeSeenAt = stored && signal.changed_at === stored.changed_at ? stored.changeSeenAt : receivedAt
      next.set(key, { ...signal, changeSeenAt })
    }
    return next
  }

  return state
}

// Labels and `@ovcs/ui` status modifiers for a node's presence.
const STATUS = {
  true: { label: 'Connected', modifier: 'ovcs-status--ok' },
  false: { label: 'Disconnected', modifier: 'ovcs-status--error' },
  null: { label: 'Status unknown', modifier: '' }
}

export const nodeStatus = (node) => STATUS[node.connected]

export const signalCount = (node) => node.sources.reduce((count, source) => count + source.signals.length, 0)

export const staleCount = (node) =>
  node.sources.reduce((count, source) => count + source.signals.filter((signal) => signal.stale === true).length, 0)

const byName = (field) => (a, b) => (a[field] < b[field] ? -1 : a[field] > b[field] ? 1 : 0)

export function groupTree(state, filterText) {
  const needle = filterText.trim().toLowerCase()
  const matches = (signal) => !needle || keyOf(signal).toLowerCase().includes(needle)
  const nodes = new Map()
  const nodeOf = (name) => {
    if (!nodes.has(name)) nodes.set(name, { node: name, connected: null, lastChange: null, sources: new Map(), shown: false })
    return nodes.get(name)
  }

  for (const signal of state.values()) {
    const node = nodeOf(signal.node)

    if (isPresence(signal)) {
      node.connected = signal.value === true
      node.shown ||= matches(signal)
      continue
    }

    node.lastChange = Math.max(node.lastChange ?? 0, signal.changed_at)
    if (!matches(signal)) continue
    node.shown = true
    if (!node.sources.has(signal.source)) node.sources.set(signal.source, [])
    node.sources.get(signal.source).push(signal)
  }

  return [...nodes.values()]
    .filter((node) => node.shown)
    .map(({ node, connected, lastChange, sources }) => ({
      node,
      connected,
      lastChange,
      sources: [...sources.entries()]
        .map(([source, signals]) => ({ source, signals: signals.sort(byName('name')) }))
        .sort(byName('source'))
    }))
    .sort(byName('node'))
}

export function splitSource(source) {
  const dot = source.lastIndexOf('.')
  return { namespace: source.slice(0, dot + 1), name: source.slice(dot + 1) }
}
