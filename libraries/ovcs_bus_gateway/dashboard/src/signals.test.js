import { describe, expect, test } from 'vitest'
import { applyFrame, groupTree, PRESENCE_SOURCE, splitSource } from './signals'

const sig = (node, source, name, value, timestamp = 1000) => ({
  node, source, name, value, unit: null, timestamp
})

const stateOf = (signals) => applyFrame(new Map(), { type: 'snapshot', signals })

describe('applyFrame', () => {
  test('snapshot replaces, update merges', () => {
    let s = applyFrame(new Map(), { type: 'snapshot', signals: [sig('vms', 'A', 'speed', 1)] })
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 2, 2000), sig('vms', 'A', 'gear', 'drive')] })
    expect(s.get('vms/A/speed').value).toBe(2)
    expect(s.size).toBe(2)
    s = applyFrame(s, { type: 'snapshot', signals: [] })
    expect(s.size).toBe(0)
  })

  test('an update older than the stored signal is ignored', () => {
    let s = stateOf([sig('vms', 'A', 'speed', 2, 2000)])
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 1, 1000)] })
    expect(s.get('vms/A/speed').value).toBe(2)
  })

  test('an update with an equal timestamp replaces the stored signal', () => {
    let s = stateOf([sig('vms', 'A', 'speed', 1, 1000)])
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 2, 1000)] })
    expect(s.get('vms/A/speed').value).toBe(2)
  })

  test('unknown frame types leave the state unchanged', () => {
    const s = stateOf([sig('vms', 'A', 'speed', 1)])
    expect(applyFrame(s, { type: 'other', signals: [] })).toBe(s)
  })

  test('stamps updated signals with the time they arrived, snapshot signals with none', () => {
    let s = applyFrame(new Map(), { type: 'snapshot', signals: [sig('vms', 'A', 'speed', 1)] }, 5000)
    expect(s.get('vms/A/speed').receivedAt).toBeNull()
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 2, 2000)] }, 6000)
    expect(s.get('vms/A/speed').receivedAt).toBe(6000)
  })
})

describe('groupTree', () => {
  test('groups by node and source and filters', () => {
    const tree = groupTree(stateOf([sig('vms', 'A', 'speed', 1), sig('bridge-ros', 'B', 'heartbeat', 1)]), 'speed')
    expect(tree).toEqual([
      expect.objectContaining({
        node: 'vms',
        sources: [{ source: 'A', signals: [expect.objectContaining({ name: 'speed' })] }]
      })
    ])
  })

  test('turns the presence signal into the node status and keeps it out of the sources', () => {
    const tree = groupTree(
      stateOf([
        sig('vms', PRESENCE_SOURCE, 'connected', true, 900),
        sig('vms', 'A', 'speed', 1, 1500),
        sig('bridge', PRESENCE_SOURCE, 'connected', false, 800)
      ]),
      ''
    )
    expect(tree.map(({ node, connected, lastChange }) => ({ node, connected, lastChange }))).toEqual([
      { node: 'bridge', connected: false, lastChange: null },
      { node: 'vms', connected: true, lastChange: 1500 }
    ])
    expect(tree[1].sources.map((s) => s.source)).toEqual(['A'])
    expect(tree[0].sources).toEqual([])
  })

  test('a node without a presence signal has an unknown status', () => {
    expect(groupTree(stateOf([sig('vms', 'A', 'speed', 1)]), '')[0].connected).toBeNull()
  })

  test('keeps a node whose only match is its name, so its status stays visible', () => {
    const tree = groupTree(stateOf([sig('bridge', PRESENCE_SOURCE, 'connected', true)]), 'bridge')
    expect(tree.map((n) => n.node)).toEqual(['bridge'])
  })

  test('sorts nodes, sources and signals by name and filters case-insensitively on the full path', () => {
    const state = stateOf([
      sig('vms', 'B', 'zeta', 1),
      sig('vms', 'A', 'beta', 1),
      sig('vms', 'A', 'alpha', 1),
      sig('bridge', 'C', 'x', 1)
    ])
    const tree = groupTree(state, '')
    expect(tree.map((n) => n.node)).toEqual(['bridge', 'vms'])
    expect(tree[1].sources.map((s) => s.source)).toEqual(['A', 'B'])
    expect(tree[1].sources[0].signals.map((s) => s.name)).toEqual(['alpha', 'beta'])
    expect(groupTree(state, 'VMS/a/BE')[0].sources[0].signals.map((s) => s.name)).toEqual(['beta'])
  })
})

describe('splitSource', () => {
  test('separates the module namespace from its last segment', () => {
    expect(splitSource('OvcsMini.Vms.MainController')).toEqual({ namespace: 'OvcsMini.Vms.', name: 'MainController' })
    expect(splitSource('Standalone')).toEqual({ namespace: '', name: 'Standalone' })
  })
})
