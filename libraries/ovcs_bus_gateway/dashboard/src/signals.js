export const keyOf = ({ node, source, name }) => `${node}/${source}/${name}`

// A signal from a forwarder that does not report publish times has a null `publishedAt`.
const publishedAt = (signal) => signal.publishedAt ?? signal.changedAt

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
      const changeSeenAt = stored && signal.changedAt === stored.changedAt ? stored.changeSeenAt : receivedAt
      next.set(key, { ...signal, changeSeenAt })
    }
    return next
  }

  return state
}

// Labels and `OvcsStatus` tones for a node's presence.
const STATUS = {
  true: { label: 'Connected', tone: 'ok' },
  false: { label: 'Disconnected', tone: 'error' },
  null: { label: 'Status unknown', tone: 'muted' }
}

export const nodeStatus = (node) => STATUS[node.connected]

export const signalCount = (node) => node.sources.reduce((count, source) => count + source.signals.length, 0)

export const staleCount = (node) =>
  node.sources.reduce((count, source) => count + source.signals.filter((signal) => signal.stale === true).length, 0)

const byName = (field) => (a, b) => (a[field] < b[field] ? -1 : a[field] > b[field] ? 1 : 0)

/**
 * The nodes of `presence`, the `status` channel's, and of the signals in `state`, each with its
 * signals by source; a node is kept when the filter matches its name or one of its signals.
 */
export function groupTree(state, filterText, presence = []) {
  const needle = filterText.trim().toLowerCase()
  const matches = (signal) => !needle || keyOf(signal).toLowerCase().includes(needle)
  const nodes = new Map()
  const nodeOf = (name) => {
    if (!nodes.has(name)) nodes.set(name, { node: name, connected: null, lastChange: null, sources: new Map(), shown: false })
    return nodes.get(name)
  }

  for (const { id, connected } of presence) {
    const node = nodeOf(id)
    node.connected = connected
    node.shown ||= !needle || id.toLowerCase().includes(needle)
  }

  for (const signal of state.values()) {
    const node = nodeOf(signal.node)
    node.lastChange = Math.max(node.lastChange ?? 0, signal.changedAt)
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

/**
 * A short name for each source of `sources`: its last segment, or as many trailing segments as it takes to tell it
 * from the others (`RadioControl.Throttle` and `RosActuatorCommand.Throttle`).
 */
export function shortNames(sources) {
  const segments = sources.map((source) => source.split('.'))
  const tail = (parts, depth) => parts.slice(-depth).join('.')

  return new Map(
    segments.map((parts, index) => {
      let depth = 1
      const clashes = () => segments.some((other, at) => at !== index && tail(other, depth) === tail(parts, depth))
      while (depth < parts.length && clashes()) depth++
      return [sources[index], tail(parts, depth)]
    })
  )
}

export function splitSource(source) {
  const dot = source.lastIndexOf('.')
  return { namespace: source.slice(0, dot + 1), name: source.slice(dot + 1) }
}
