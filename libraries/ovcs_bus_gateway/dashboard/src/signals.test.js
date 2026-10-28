import { describe, expect, test } from 'vitest'
import { applyFrame, groupTree, nodeStatus, PRESENCE_SOURCE, signalCount, splitSource, staleCount } from './signals'

describe('nodeStatus and signalCount', () => {
  test('label the presence and count the signals of a node', () => {
    const node = { connected: false, sources: [{ signals: [{}, {}] }, { signals: [{}] }] }
    expect(nodeStatus(node).label).toBe('Disconnected')
    expect(nodeStatus({ ...node, connected: null }).label).toBe('Status unknown')
    expect(signalCount(node)).toBe(3)
  })
})

const sig = (node, source, name, value, changedAt = 1000, publishedAt = changedAt, stale = false) => ({
  node, source, name, value, unit: null, changed_at: changedAt, published_at: publishedAt, stale
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

  test('an update published before the stored signal is ignored', () => {
    let s = stateOf([sig('vms', 'A', 'speed', 2, 2000, 3000)])
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 2, 2000, 2500)] })
    expect(s.get('vms/A/speed').published_at).toBe(3000)
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 1, 1000)] })
    expect(s.get('vms/A/speed').value).toBe(2)
  })

  test('orders signals without a publish time by their change time', () => {
    let s = stateOf([sig('vms', 'A', 'speed', 2, 2000, null)])
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 1, 1000, null)] })
    expect(s.get('vms/A/speed').value).toBe(2)
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 3, 3000, null)] })
    expect(s.get('vms/A/speed').value).toBe(3)
  })

  test('a stale flag update replaces the stored signal', () => {
    let s = stateOf([sig('vms', 'A', 'speed', 1, 1000, 2000)])
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 1, 1000, 2000, true)] })
    expect(s.get('vms/A/speed').stale).toBe(true)
  })

  test('an update published at the same time replaces the stored signal', () => {
    let s = stateOf([sig('vms', 'A', 'speed', 1, 1000)])
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 2, 1000)] })
    expect(s.get('vms/A/speed').value).toBe(2)
  })

  test('unknown frame types leave the state unchanged', () => {
    const s = stateOf([sig('vms', 'A', 'speed', 1)])
    expect(applyFrame(s, { type: 'other', signals: [] })).toBe(s)
  })

  test('stamps changeSeenAt only when an update changes changed_at', () => {
    let s = applyFrame(new Map(), { type: 'snapshot', signals: [sig('vms', 'A', 'speed', 1)] }, 5000)
    expect(s.get('vms/A/speed').changeSeenAt).toBeNull()
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 1, 1000, 2000)] }, 6000)
    expect(s.get('vms/A/speed').changeSeenAt).toBeNull()
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 2, 3000)] }, 7000)
    expect(s.get('vms/A/speed').changeSeenAt).toBe(7000)
    s = applyFrame(s, { type: 'update', signals: [sig('vms', 'A', 'speed', 2, 3000, 4000)] }, 8000)
    expect(s.get('vms/A/speed').changeSeenAt).toBe(7000)
  })

  test('a signal first seen in an update has changed', () => {
    const s = applyFrame(new Map(), { type: 'update', signals: [sig('vms', 'A', 'speed', 1)] }, 6000)
    expect(s.get('vms/A/speed').changeSeenAt).toBe(6000)
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

describe('staleCount', () => {
  test('counts the signals of a node the gateway marked stale', () => {
    const [node] = groupTree(
      stateOf([
        sig('vms', 'A', 'speed', 1, 1000, 1000, true),
        sig('vms', 'A', 'gear', 1, 1000, 1000, false),
        sig('vms', 'B', 'old', 1, 1000, null, null)
      ]),
      ''
    )
    expect(staleCount(node)).toBe(1)
  })
})

describe('splitSource', () => {
  test('separates the module namespace from its last segment', () => {
    expect(splitSource('OvcsMini.Vms.MainController')).toEqual({ namespace: 'OvcsMini.Vms.', name: 'MainController' })
    expect(splitSource('Standalone')).toEqual({ namespace: '', name: 'Standalone' })
  })
})
