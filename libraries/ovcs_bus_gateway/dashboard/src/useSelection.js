import { useCallback, useState } from 'react'

const NODE = 'node'
const SOURCE = 'source'
const ADAPTER = 'adapter'

/** The node and source, or the adapter, the URL names; a source counts only with its node, an adapter only without. */
export function selectionFromUrl(search = window.location.search) {
  const params = new URLSearchParams(search)
  const node = params.get(NODE)
  return { node, source: node ? params.get(SOURCE) : null, adapter: node ? null : params.get(ADAPTER) }
}

function writeUrl({ node, source, adapter }) {
  const url = new URL(window.location.href)
  for (const parameter of [NODE, SOURCE, ADAPTER]) url.searchParams.delete(parameter)
  if (node) url.searchParams.set(NODE, node)
  if (node && source) url.searchParams.set(SOURCE, source)
  if (adapter) url.searchParams.set(ADAPTER, adapter)
  window.history.replaceState(window.history.state, '', url)
}

/**
 * The selected node and source, or adapter, kept in the URL without a new history entry. `select(null)` is the whole
 * bus, `select(node)` a node with all its sources, `select(node, source)` one of them, `openAdapter(id)` an adapter.
 */
export function useSelection() {
  const [selection, setSelection] = useState(selectionFromUrl)

  const change = useCallback((next) => {
    writeUrl(next)
    setSelection(next)
  }, [])
  const select = useCallback(
    (node, source = null) => change({ node, source: node ? source : null, adapter: null }),
    [change]
  )
  const openAdapter = useCallback((adapter) => change({ node: null, source: null, adapter }), [change])

  return [selection, select, openAdapter]
}
