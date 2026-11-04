/**
 * A page's sections, in order: a full-width block alone, or the blocks between two of them dealt to `count` columns
 * in turn, so each column stacks its blocks without waiting for a taller neighbour.
 */
export function blockLayout(blocks, count) {
  const sections = []
  let columns = null
  let next = 0

  for (const block of blocks) {
    if (block.fullWidth) {
      sections.push({ block })
      columns = null
      continue
    }
    if (columns === null) {
      columns = Array.from({ length: count }, () => [])
      next = 0
      sections.push({ columns })
    }
    columns[next].push(block)
    next = (next + 1) % count
  }

  return sections
}
