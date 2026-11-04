import { describe, it, expect } from 'vitest'
import { blockLayout } from '../layout.js'

const block = (id, fullWidth = null) => ({ id, fullWidth })
const ids = (layout) =>
  layout.map((section) => (section.block ? section.block.id : section.columns.map((column) => column.map(({ id }) => id))))

describe('layout', () => {
  it('deals the blocks to the columns in order, each column stacking its own', () => {
    expect(ids(blockLayout([block('a'), block('b'), block('c'), block('d'), block('e')], 3))).toEqual([
      [['a', 'd'], ['b', 'e'], ['c']]
    ])
  })

  it('gives a full-width block its own row and deals the next blocks from the first column again', () => {
    expect(ids(blockLayout([block('a'), block('b'), block('wide', true), block('c')], 3))).toEqual([
      [['a'], ['b'], []],
      'wide',
      [['c'], [], []]
    ])
  })

  it('stacks every block in order in one column', () => {
    expect(ids(blockLayout([block('a'), block('wide', true), block('b')], 1))).toEqual([[['a']], 'wide', [['b']]])
  })

  it('has nothing to lay out without blocks', () => {
    expect(blockLayout([], 3)).toEqual([])
  })
})
