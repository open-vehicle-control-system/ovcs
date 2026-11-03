import { fireEvent, render, screen, within } from '@testing-library/react'
import { describe, expect, test, vi } from 'vitest'

import BusDiagram from './BusDiagram.jsx'

const NOW = 100_000

const signal = (publishedAgo, stale = false) => ({ name: 'speed', stale, published_at: NOW - publishedAgo, changeSeenAt: null })

const node = (name, connected, sources = []) => ({ node: name, connected, lastChange: null, sources })

const show = (bus, selected = null, onSelect = vi.fn()) =>
  render(<BusDiagram bus={bus} selected={selected} onSelect={onSelect} now={NOW} />)

const block = (name) => screen.getByRole('button', { name: new RegExp(`^${name},`) })
const link = (name) => block(name).parentElement.querySelector('[data-link]')

describe('BusDiagram', () => {
  test('plugs every node into the bus, with its status and what it publishes', () => {
    show([
      node('vms', true, [{ source: 'A', signals: [signal(500), signal(500, true)] }, { source: 'B', signals: [signal(9000)] }]),
      node('bridge-ros', true)
    ])
    const nodes = screen.getByRole('list', { name: 'Nodes on the bus' })
    expect(within(nodes).getAllByRole('listitem')).toHaveLength(2)
    expect(block('vms').getAttribute('aria-label')).toBe('vms, Connected, 2 components · 3 signals')
    expect(block('vms').textContent).toContain('· 1 stale')
    expect(block('bridge-ros').textContent).toContain('Presence only')
  })

  test("pulses a node's link while it publishes, and draws it still once it stops", () => {
    show([node('vms', true, [{ source: 'A', signals: [signal(500)] }]), node('bridge', true, [{ source: 'B', signals: [signal(9000)] }])])
    expect(link('vms').className).toContain('animate-pulse')
    expect(link('bridge').className).not.toContain('animate-pulse')
    expect(link('bridge').className).toContain('bg-ovcs-accent')
  })

  test('draws a dropped node in red with a dashed link', () => {
    show([node('bridge-radio-control', false)])
    expect(block('bridge-radio-control').className).toContain('border-ovcs-error')
    expect(block('bridge-radio-control').textContent).toContain('Disconnected')
    expect(link('bridge-radio-control').className).toContain('repeating-linear-gradient')
  })

  test('selects a node and marks the selected one', () => {
    const onSelect = vi.fn()
    show([node('vms', true), node('bridge-ros', true)], 'vms', onSelect)
    expect(block('vms').getAttribute('aria-current')).toBe('true')
    expect(block('bridge-ros').getAttribute('aria-current')).toBeNull()
    fireEvent.click(block('bridge-ros'))
    expect(onSelect).toHaveBeenCalledWith('bridge-ros')
  })
})
