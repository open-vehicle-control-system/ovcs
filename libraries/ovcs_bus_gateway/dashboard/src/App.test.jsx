import { fireEvent, render, screen, within } from '@testing-library/react'
import { beforeEach, describe, expect, test, vi } from 'vitest'

import App from './App.jsx'
import { applyFrame, PRESENCE_SOURCE } from './signals'
import { useBusSocket } from './useBusSocket'

vi.mock('./useBusSocket', () => ({ useBusSocket: vi.fn() }))

const sig = (node, source, name, value) => ({
  node, source, name, value, unit: null, changedAt: 1000, publishedAt: 1000, stale: false
})

const SIGNALS = [
  sig('vms', PRESENCE_SOURCE, 'connected', true),
  sig('vms', 'VmsCore.Managers.Gear', 'selected_gear', 'drive'),
  sig('vms', 'OvcsMini.Vms.MainController', 'throttle', 0.4),
  sig('bridge-ros', PRESENCE_SOURCE, 'connected', true)
]

const connect = (status, signals = []) =>
  useBusSocket.mockReturnValue({ status, signals: applyFrame(new Map(), { type: 'snapshot', signals }) })

const filter = () => screen.getByRole('searchbox', { name: 'Filter signals' })
const menu = () => screen.getByRole('navigation', { name: 'Bus gateway' })
const bus = () => screen.getByRole('list', { name: 'Nodes on the bus' })
const showAt = (search) => {
  window.history.replaceState(null, '', `/${search}`)
  return render(<App />)
}

describe('App', () => {
  beforeEach(() => {
    useBusSocket.mockReset()
    window.history.replaceState(null, '', '/')
  })

  test('waits for the first snapshot', () => {
    connect('connecting')
    render(<App />)
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('OVCS Bus Gateway')
    expect(screen.getByText('Loading signals…')).toBeTruthy()
    expect(screen.getByText('Connecting…')).toBeTruthy()
  })

  test('shows every node on the bus and in the menu, and every signal under the bus', () => {
    connect('live', SIGNALS)
    render(<App />)
    expect(screen.getByText('Live · 2 signals')).toBeTruthy()
    expect(within(bus()).getAllByRole('button').map((node) => node.getAttribute('aria-label'))).toEqual([
      'bridge-ros, Connected, Presence only',
      'vms, Connected, 2 components · 2 signals'
    ])
    expect(within(menu()).getByRole('button', { name: /^Bus/ }).getAttribute('aria-current')).toBe('page')
    expect(within(menu()).getByRole('button', { name: /^vms\b.*Connected/ })).toBeTruthy()
    expect(screen.getByRole('heading', { level: 2, name: 'vms' })).toBeTruthy()
    expect(screen.getByTitle('selected_gear')).toBeTruthy()
  })

  test("opens a node from the menu, then one of its components, and keeps them in the URL", () => {
    connect('live', SIGNALS)
    render(<App />)

    fireEvent.click(within(menu()).getByRole('button', { name: /^vms/ }))
    expect(window.location.search).toBe('?node=vms')
    const tabs = screen.getByRole('list', { name: 'Components of vms' })
    expect(within(tabs).getAllByRole('button').map((tab) => tab.textContent)).toEqual(['All2', 'MainController1', 'Gear1'])
    expect(screen.getByTitle('throttle')).toBeTruthy()

    fireEvent.click(within(tabs).getByRole('button', { name: /^Gear/ }))
    expect(new URLSearchParams(window.location.search).get('source')).toBe('VmsCore.Managers.Gear')
    expect(screen.getByTitle('selected_gear')).toBeTruthy()
    expect(screen.queryByTitle('throttle')).toBeNull()

    fireEvent.click(within(menu()).getByRole('button', { name: /^Bus/ }))
    expect(window.location.search).toBe('')
  })

  test('opens the node and component the URL names, and selects a node from the bus', () => {
    connect('live', SIGNALS)
    showAt('?node=vms&source=OvcsMini.Vms.MainController')
    expect(screen.getByTitle('throttle')).toBeTruthy()
    expect(screen.queryByTitle('selected_gear')).toBeNull()

    fireEvent.click(within(bus()).getByRole('button', { name: /^bridge-ros/ }))
    expect(window.location.search).toBe('?node=bridge-ros')
    expect(screen.getByText('bridge-ros publishes no signals: it only reports its presence.')).toBeTruthy()
  })

  test('says when the URL names a node the bus does not have', () => {
    connect('live', SIGNALS)
    showAt('?node=infotainment')
    expect(screen.getByText('infotainment is not on the bus.')).toBeTruthy()
  })

  test('filters the signals but keeps every node on the bus', () => {
    connect('live', SIGNALS)
    render(<App />)
    fireEvent.change(filter(), { target: { value: 'nothing' } })
    expect(screen.getByText('No signals match.')).toBeTruthy()
    expect(within(bus()).getAllByRole('button')).toHaveLength(2)
  })

  test('says when the gateway has no signals', () => {
    connect('live')
    render(<App />)
    expect(screen.getByText('The gateway has no signals yet.')).toBeTruthy()
  })

  test('"/" focuses the filter, but types as usual in a field', () => {
    connect('live')
    render(<App />)
    fireEvent.keyDown(document.body, { key: '/' })
    expect(document.activeElement).toBe(filter())
    expect(fireEvent.keyDown(filter(), { key: '/' })).toBe(true)
  })

  test('reports a lost connection', () => {
    connect('disconnected')
    render(<App />)
    expect(screen.getByText('Disconnected, retrying')).toBeTruthy()
  })
})
