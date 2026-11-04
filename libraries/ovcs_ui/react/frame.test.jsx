import { act, fireEvent, render, renderHook, screen, within } from '@testing-library/react'
import { describe, expect, test, vi } from 'vitest'

import {
  OvcsBottomBar,
  OvcsBottomBarItem,
  OvcsConnectionStatus,
  OvcsMain,
  OvcsMenu,
  OvcsMenuItem,
  OvcsMenuList,
  OvcsMenuSection,
  OvcsPageFrame,
  OvcsShell,
  OvcsShellBody,
  OvcsTopBar,
  firmwareFacts,
  useOvcsConnection,
  useOvcsFirmware
} from './index.js'

describe('the page frame', () => {
  test('puts the top bar over the menu and the main content', () => {
    render(
      <OvcsShell product="Vision">
        <OvcsTopBar />
        <OvcsShellBody>
          <OvcsMenu label="Vision unit" />
          <OvcsMain>content</OvcsMain>
        </OvcsShellBody>
        <OvcsBottomBar />
      </OvcsShell>
    )

    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('OVCS Vision')
    expect(screen.getByRole('banner').classList).toContain('ovcs-header')
    expect(screen.getByRole('contentinfo')).toBeTruthy()
    expect(screen.getByRole('navigation', { name: 'Vision unit' })).toBeTruthy()
    expect(screen.getByRole('main').textContent).toBe('content')
  })
})

describe('OvcsTopBar', () => {
  const board = { revision: 'ce99e251', target: 'rpi5', nervesSystem: 'nerves_system_rpi5', nervesSystemVersion: '2.0.1', vehicle: 'OVCS Mini' }

  test("names the product and its firmware, then its children, then the theme switch", () => {
    render(
      <OvcsShell product="Vision">
        <OvcsTopBar firmware={board}>
          <p>alert</p>
        </OvcsTopBar>
      </OvcsShell>
    )

    const banner = screen.getByRole('banner')
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('OVCS Vision')
    const facts = banner.querySelector('dl')
    expect(facts.getAttribute('aria-label')).toBe('Firmware')
    expect(within(facts).getByText('ce99e251').previousSibling.textContent).toBe('Version')
    expect(facts.textContent).toBe('Versionce99e251Systemnerves_system_rpi5 2.0.1VehicleOVCS Mini')
    expect(banner.textContent).toContain('alert')
    expect(within(banner).getByRole('switch', { name: 'Dark mode' })).toBeTruthy()
  })

  test('shows no firmware line before the firmware is known', () => {
    render(
      <OvcsShell product="VMS">
        <OvcsTopBar />
      </OvcsShell>
    )
    expect(screen.getByRole('banner').querySelector('dl')).toBeNull()
    expect(document.title).toBe('OVCS VMS')
  })

  test('titles the browser tab with the product and the vehicle', () => {
    render(
      <OvcsShell product="Bus Gateway">
        <OvcsTopBar firmware={board} />
      </OvcsShell>
    )
    expect(document.title).toBe('OVCS Bus Gateway · OVCS Mini')
  })
})

describe('useOvcsFirmware', () => {
  const flush = () => act(() => Promise.resolve())

  test('reads the firmware each time the dashboard connects, and keeps it when a read fails', async () => {
    const fetchFirmware = vi.fn().mockResolvedValue({ revision: 'ce99e251' })
    const { result, rerender } = renderHook(({ connected }) => useOvcsFirmware(fetchFirmware, connected), {
      initialProps: { connected: false }
    })
    await flush()
    expect(fetchFirmware).not.toHaveBeenCalled()
    expect(result.current).toBeNull()

    rerender({ connected: true })
    await flush()
    expect(result.current).toEqual({ revision: 'ce99e251' })

    fetchFirmware.mockResolvedValue({ revision: '7ee101da' })
    rerender({ connected: false })
    rerender({ connected: true })
    await flush()
    expect(fetchFirmware).toHaveBeenCalledTimes(2)
    expect(result.current).toEqual({ revision: '7ee101da' })

    fetchFirmware.mockRejectedValue(new Error('offline'))
    rerender({ connected: false })
    rerender({ connected: true })
    await flush()
    expect(result.current).toEqual({ revision: '7ee101da' })
  })
})

describe('firmwareFacts', () => {
  test('names the target where there is no Nerves system, and leaves a missing part out', () => {
    expect(firmwareFacts({ revision: 'ce99e251-dirty', target: 'host', nervesSystem: null, vehicle: null })).toEqual([
      ['Version', 'ce99e251-dirty'],
      ['System', 'host']
    ])
    expect(firmwareFacts({ revision: null, target: 'host', vehicle: 'OVCS1' })).toEqual([
      ['System', 'host'],
      ['Vehicle', 'OVCS1']
    ])
    expect(firmwareFacts(null)).toEqual([])
  })
})

describe('OvcsBottomBar', () => {
  test('holds the statuses in the page footer, each value after its label', () => {
    render(
      <OvcsBottomBar>
        <OvcsBottomBarItem label="Vision unit">
          <span>Connected</span>
        </OvcsBottomBarItem>
      </OvcsBottomBar>
    )

    const footer = screen.getByRole('contentinfo')
    expect(footer.classList).toContain('ovcs-footer')
    expect(footer.textContent).toBe('Vision unitConnected')
    expect(within(footer).getByRole('list', { name: 'Status' }).children).toHaveLength(1)
  })
})

describe('the connection', () => {
  // A Phoenix socket whose callbacks the test fires.
  const fakeSocket = (connected) => {
    const callbacks = {}
    return {
      callbacks,
      isConnected: () => connected,
      onOpen: (callback) => ((callbacks.open = callback), 'open'),
      onClose: (callback) => ((callbacks.close = callback), 'close'),
      onError: (callback) => ((callbacks.error = callback), 'error'),
      off: vi.fn()
    }
  }

  test('follows the socket as it opens, closes and fails, and stops when unmounted', () => {
    const socket = fakeSocket(false)
    const { result, unmount } = renderHook(() => useOvcsConnection(socket))
    expect(result.current).toBe('connecting')

    act(() => socket.callbacks.open())
    expect(result.current).toBe('connected')
    act(() => socket.callbacks.error())
    expect(result.current).toBe('disconnected')

    unmount()
    expect(socket.off).toHaveBeenCalledWith(['open', 'close', 'error'])
  })

  test('is connected when the socket already is', () => {
    const { result } = renderHook(() => useOvcsConnection(fakeSocket(true)))
    expect(result.current).toBe('connected')
  })

  test("names each state with its tone, after the shell's product", () => {
    const connection = (state) => (
      <OvcsShell product="Vision">
        <OvcsConnectionStatus state={state} hint={<span>ⓘ</span>} />
      </OvcsShell>
    )
    const { rerender, container } = render(connection('connected'))
    expect(container.textContent).toBe('VisionⓘConnected')
    expect(screen.getByText('Connected').classList).toContain('ovcs-status--ok')

    rerender(connection('disconnected'))
    expect(screen.getByText('Disconnected').classList).toContain('ovcs-status--error')

    rerender(connection('connecting'))
    expect(screen.getByText('Connecting…')).toBeTruthy()
  })
})

describe('OvcsMenu', () => {
  test('names each section by its title and marks the selected item as the current page', () => {
    const onClick = vi.fn()
    render(
      <OvcsMenu label="Bus">
        <OvcsMenuSection title="Nodes">
          <OvcsMenuList label="Nodes">
            <li>
              <OvcsMenuItem selected>vms</OvcsMenuItem>
            </li>
            <li>
              <OvcsMenuItem onClick={onClick}>bridge-ros</OvcsMenuItem>
            </li>
          </OvcsMenuList>
        </OvcsMenuSection>
      </OvcsMenu>
    )

    const section = screen.getByRole('region', { name: 'Nodes' })
    const [vms, ros] = within(within(section).getByRole('list', { name: 'Nodes' })).getAllByRole('button')
    expect(vms.getAttribute('aria-current')).toBe('page')
    expect(vms.className).toContain('shadow-[inset_3px_0_0_var(--ovcs-accent)]')
    expect(ros.getAttribute('aria-current')).toBeNull()
    expect(ros.className).toContain('hover:bg-ovcs-bg')
    fireEvent.click(ros)
    expect(onClick).toHaveBeenCalled()
  })

  test('lets an item name another kind of current entry', () => {
    render(
      <OvcsMenuItem selected aria-current="true">
        Cameras
      </OvcsMenuItem>
    )
    expect(screen.getByRole('button').getAttribute('aria-current')).toBe('true')
  })
})

describe('OvcsPageFrame', () => {
  test('heads its content with the title and the summary', () => {
    render(
      <OvcsPageFrame title="ROS 2" summary="What this unit publishes.">
        <p>topics</p>
      </OvcsPageFrame>
    )
    expect(screen.getByRole('heading', { level: 2 }).textContent).toBe('ROS 2')
    expect(screen.getByText('What this unit publishes.')).toBeTruthy()
    expect(screen.getByText('topics')).toBeTruthy()
  })
})
