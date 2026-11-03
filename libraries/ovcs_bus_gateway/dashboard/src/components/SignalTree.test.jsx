import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, test } from 'vitest'

import { applyFrame, groupTree } from '../signals'
import SignalTree, { SourceTable, useCollapsed } from './SignalTree.jsx'

const NOW = 100_000

const sig = (name, overrides = {}) => ({
  node: 'vms', source: 'OvcsMini.Vms.Speed', name, value: 1, unit: null,
  changedAt: NOW - 5000, publishedAt: NOW - 500, stale: false, ...overrides
})

const treeOf = (signals, filter = '') => groupTree(applyFrame(new Map(), { type: 'snapshot', signals }), filter)

function Tree({ tree }) {
  const [collapsed, toggle] = useCollapsed()
  return <SignalTree tree={tree} collapsed={collapsed} onToggle={toggle} now={NOW} />
}

const row = (name) => screen.getByTitle(name).closest('.ovcs-row')
const sourceButton = () => screen.getByRole('button', { name: /Speed/ })

describe('SignalTree', () => {
  test('heads each node with its name and status, and each source with its full name and signal count', () => {
    render(<Tree tree={treeOf([sig('speed'), sig('limit')])} />)
    expect(screen.getByRole('heading', { level: 2, name: 'vms' })).toBeTruthy()
    expect(sourceButton().getAttribute('title')).toBe('OvcsMini.Vms.Speed')
    expect(sourceButton().textContent).toContain('OvcsMini.Vms.')
    expect(sourceButton().textContent).toContain('2')
  })

  test('folds a source away and back', () => {
    render(<Tree tree={treeOf([sig('speed')])} />)
    fireEvent.click(sourceButton())
    expect(sourceButton().getAttribute('aria-expanded')).toBe('false')
    expect(screen.queryByTitle('speed')).toBeNull()
    fireEvent.click(sourceButton())
    expect(screen.getByTitle('speed')).toBeTruthy()
  })

  test('keeps a source folded while a filter hides its node', () => {
    const signals = [sig('speed'), { ...sig('heartbeat'), node: 'bridge', source: 'B' }]
    const { rerender } = render(<Tree tree={treeOf(signals)} />)
    fireEvent.click(sourceButton())
    rerender(<Tree tree={treeOf(signals, 'heartbeat')} />)
    expect(screen.queryByRole('button', { name: /Speed/ })).toBeNull()
    rerender(<Tree tree={treeOf(signals)} />)
    expect(sourceButton().getAttribute('aria-expanded')).toBe('false')
  })

  test('labels a stale signal and dims its value', () => {
    render(<Tree tree={treeOf([sig('speed', { stale: true })])} />)
    expect(row('speed').querySelector('.ovcs-badge--warn').textContent).toBe('stale')
    expect(screen.getByTitle('1').className).toContain('text-ovcs-muted')
    expect(screen.getByText('1 stale')).toBeTruthy()
  })

  test('marks a signal whose firmware does not report publications', () => {
    render(<Tree tree={treeOf([sig('speed', { publishedAt: null })])} />)
    expect(screen.getByTitle("This node's firmware does not report publications").textContent).toBe('—')
  })

  test('lights a row whose value changed within the live window', () => {
    let state = applyFrame(new Map(), { type: 'snapshot', signals: [sig('speed'), sig('limit')] })
    state = applyFrame(state, { type: 'update', signals: [sig('speed', { value: 2, changedAt: NOW - 100 })] }, NOW - 500)
    render(<Tree tree={groupTree(state, '')} />)
    expect(row('speed').classList).toContain('ovcs-row--live')
    expect(row('speed').querySelector('.ovcs-dot--on')).not.toBeNull()
    expect(row('limit').classList).not.toContain('ovcs-row--live')
  })

  test('leaves out a node that publishes no signals', () => {
    const tree = [{ node: 'bridge', connected: true, lastChange: null, sources: [] }]
    const { container } = render(<Tree tree={tree} />)
    expect(container.querySelector('section')).toBeNull()
  })
})

describe('SourceTable', () => {
  test("lists one source's signals without a header to fold them", () => {
    const [node] = treeOf([sig('speed'), sig('limit')])
    render(<SourceTable source={node.sources[0]} now={NOW} />)
    expect(screen.getByTitle('speed')).toBeTruthy()
    expect(screen.queryByRole('button')).toBeNull()
  })
})
