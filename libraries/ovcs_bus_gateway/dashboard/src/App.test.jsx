import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, test, vi } from 'vitest'

import App from './App.jsx'
import { applyFrame } from './signals'
import { useBusSocket } from './useBusSocket'

vi.mock('./useBusSocket', () => ({ useBusSocket: vi.fn() }))
vi.mock('./firmware', () => ({
  fetchFirmware: vi.fn(async () => ({ revision: 'ce99e251', target: 'rpi5', nervesSystem: null, vehicle: 'OVCS Mini' }))
}))

const sig = (node, source, name, value) => ({
  node, source, name, value, unit: null, changedAt: 1000, publishedAt: 1000, stale: false
})

const SIGNALS = [
  sig('vms', 'VmsCore.Managers.Gear', 'selected_gear', 'drive'),
  sig('vms', 'OvcsMini.Vms.MainController', 'throttle', 0.4)
]

const NODES = [
  { id: 'bridge-ros', connected: true },
  { id: 'vms', connected: true }
]

const ADAPTERS = [
  {
    id: 'mqtt',
    name: 'MQTT',
    module: 'OvcsBusGateway.Mqtt',
    status: { level: 'warning', detail: 'Not connected to 10.42.0.1:1883' },
    broker: '10.42.0.1:1883',
    clientId: 'ovcs_bus_gateway_ovcs_mini_ros_target',
    topic: 'ovcs/<node>/<source>/<name>'
  },
  {
    id: 'http',
    name: 'HTTP',
    module: 'OvcsBusGateway.Http',
    status: { level: 'ok', detail: 'Answering on port 4100' },
    port: 4100,
    clients: 1
  }
]

const connect = (status, signals = [], { nodes = NODES, adapters = ADAPTERS } = {}) =>
  useBusSocket.mockReturnValue({
    status,
    signals: applyFrame(new Map(), { type: 'snapshot', signals }),
    nodes,
    adapters
  })

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
    expect(within(screen.getByRole('contentinfo')).getByText('Connecting…')).toBeTruthy()
  })

  test('shows every node on the bus and in the menu, and every signal under the bus', () => {
    connect('live', SIGNALS)
    render(<App />)
    const footer = screen.getByRole('contentinfo')
    expect(footer.textContent).toBe('Bus GatewayConnectedSignals2')
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

  test('says when the gateway has no signals, and when its nodes publish none', () => {
    connect('live', [], { nodes: [] })
    const { rerender } = render(<App />)
    expect(screen.getByText('The gateway has no signals yet.')).toBeTruthy()

    connect('live')
    rerender(<App />)
    expect(screen.getByText('No node publishes signals yet.')).toBeTruthy()
    expect(within(bus()).getAllByRole('button')).toHaveLength(2)
  })

  test('lists the adapters with their status and opens one, keeping it in the URL', () => {
    connect('live', SIGNALS)
    render(<App />)

    const adapters = screen.getByRole('list', { name: 'Adapters' })
    const mqtt = within(adapters).getByRole('button', { name: /^MQTT/ })
    expect(mqtt.querySelector('.ovcs-status--error')).not.toBeNull()
    expect(within(adapters).getByRole('button', { name: /^HTTP/ }).querySelector('.ovcs-status--ok')).not.toBeNull()

    fireEvent.click(mqtt)
    expect(window.location.search).toBe('?adapter=mqtt')
    expect(mqtt.getAttribute('aria-current')).toBe('page')
    expect(screen.getByRole('heading', { level: 2, name: 'MQTT' })).toBeTruthy()
    expect(screen.getByText('Not connected to 10.42.0.1:1883')).toBeTruthy()
    expect(screen.getByText('ovcs/<node>/<source>/<name>')).toBeTruthy()
    expect(screen.queryByRole('list', { name: 'Nodes on the bus' })).toBeNull()

    fireEvent.click(within(menu()).getByRole('button', { name: /^vms/ }))
    expect(window.location.search).toBe('?node=vms')
  })

  test('opens the adapter the URL names', () => {
    connect('live', SIGNALS)
    showAt('?adapter=http')
    expect(screen.getByRole('heading', { level: 2, name: 'HTTP' })).toBeTruthy()
    expect(screen.getByText('Signal streams open').nextSibling.textContent).toBe('1')
  })

  test('waits for the adapters, and says when the URL names one the gateway does not have', () => {
    connect('live', SIGNALS, { adapters: null })
    const { rerender } = showAt('?adapter=mqtt')
    expect(screen.getByText('Loading adapters…')).toBeTruthy()

    connect('live', SIGNALS)
    window.history.replaceState(null, '', '/?adapter=ros2')
    rerender(<App key="again" />)
    expect(screen.getByText('The gateway has no adapter ros2.')).toBeTruthy()
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
    expect(screen.getByRole('contentinfo').textContent).toBe('Bus GatewayDisconnected')
  })

  test('names the firmware and its vehicle in the top bar once live', async () => {
    connect('live', SIGNALS)
    render(<App />)
    const topBar = screen.getByRole('heading', { level: 1 }).closest('header')
    expect(await within(topBar).findByText('OVCS Mini')).toBeTruthy()
    // The title is set in an effect, which can run after the text shows.
    await waitFor(() => expect(document.title).toBe('OVCS Bus Gateway · OVCS Mini'))
  })
})
