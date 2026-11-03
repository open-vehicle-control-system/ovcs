import { useCallback, useState } from 'react'

const NODE = 'node'
const SOURCE = 'source'

/** The node and source the URL names; a source counts only with its node. */
export function selectionFromUrl(search = window.location.search) {
  const params = new URLSearchParams(search)
  const node = params.get(NODE)
  return { node, source: node ? params.get(SOURCE) : null }
}

function writeUrl({ node, source }) {
  const url = new URL(window.location.href)
  url.searchParams.delete(NODE)
  url.searchParams.delete(SOURCE)
  if (node) url.searchParams.set(NODE, node)
  if (node && source) url.searchParams.set(SOURCE, source)
  window.history.replaceState(window.history.state, '', url)
}

/**
 * The selected node and source, kept in the URL without a new history entry. `select(null)` is the whole bus,
 * `select(node)` a node with all its sources, `select(node, source)` one of them.
 */
export function useSelection() {
  const [selection, setSelection] = useState(selectionFromUrl)
  const select = useCallback((node, source = null) => {
    const next = { node, source: node ? source : null }
    writeUrl(next)
    setSelection(next)
  }, [])
  return [selection, select]
}
