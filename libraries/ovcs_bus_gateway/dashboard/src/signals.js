export const keyOf = ({ node, source, name }) => `${node}/${source}/${name}`

// Returns a new Map. A snapshot replaces the state; an update merges newer signals into it.
export function applyFrame(state, frame) {
  if (frame.type === 'snapshot') {
    return new Map(frame.signals.map((signal) => [keyOf(signal), signal]))
  }

  if (frame.type === 'update') {
    const next = new Map(state)
    for (const signal of frame.signals) {
      const key = keyOf(signal)
      const stored = next.get(key)
      if (!stored || signal.timestamp >= stored.timestamp) next.set(key, signal)
    }
    return next
  }

  return state
}

const byName = (field) => (a, b) => (a[field] < b[field] ? -1 : a[field] > b[field] ? 1 : 0)

export function groupTree(state, filterText) {
  const needle = filterText.trim().toLowerCase()
  const nodes = new Map()

  for (const signal of state.values()) {
    if (needle && !keyOf(signal).toLowerCase().includes(needle)) continue
    if (!nodes.has(signal.node)) nodes.set(signal.node, new Map())
    const sources = nodes.get(signal.node)
    if (!sources.has(signal.source)) sources.set(signal.source, [])
    sources.get(signal.source).push(signal)
  }

  return [...nodes.entries()]
    .map(([node, sources]) => ({
      node,
      sources: [...sources.entries()]
        .map(([source, signals]) => ({ source, signals: signals.sort(byName('name')) }))
        .sort(byName('source'))
    }))
    .sort(byName('node'))
}
