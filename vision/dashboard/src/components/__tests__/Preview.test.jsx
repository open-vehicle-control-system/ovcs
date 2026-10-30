import { describe, it, expect, vi } from 'vitest'
import { render, screen, act, fireEvent } from '@testing-library/react'
import Preview from '../Preview.jsx'

function fakeSocket() {
  const handlers = {}
  const channel = {
    on: vi.fn((event, handler) => { handlers[event] = handler }),
    join: vi.fn(() => ({ receive: vi.fn() })),
    push: vi.fn(),
    leave: vi.fn()
  }
  return { channel: vi.fn(() => channel), handlers, fakeChannel: channel }
}

const sendFrame = (socket, jpeg) => act(() => socket.handlers.frame({ jpeg }))

describe('Preview', () => {
  it('renders the latest frame', () => {
    const socket = fakeSocket()
    render(<Preview stream="left" socket={socket} />)

    expect(socket.channel).toHaveBeenCalledWith('preview:left', {})
    sendFrame(socket, 'Zmlyc3Q=')
    sendFrame(socket, 'bGF0ZXN0')

    expect(screen.getByRole('img', { name: 'left preview' }).getAttribute('src')).toBe('data:image/jpeg;base64,bGF0ZXN0')
  })

  it('acks a frame once the image has loaded or failed', () => {
    const socket = fakeSocket()
    render(<Preview stream="left" socket={socket} />)

    sendFrame(socket, 'Zmlyc3Q=')
    expect(socket.fakeChannel.push).not.toHaveBeenCalled()

    fireEvent.load(screen.getByRole('img'))
    expect(socket.fakeChannel.push).toHaveBeenCalledWith('ack', {})

    sendFrame(socket, 'bGF0ZXN0')
    fireEvent.error(screen.getByRole('img'))
    expect(socket.fakeChannel.push).toHaveBeenCalledTimes(2)
  })

  it('acks an unchanged frame at once, as it fires no load event', () => {
    const socket = fakeSocket()
    render(<Preview stream="left" socket={socket} />)

    sendFrame(socket, 'Zmlyc3Q=')
    sendFrame(socket, 'Zmlyc3Q=')

    expect(socket.fakeChannel.push).toHaveBeenCalledWith('ack', {})
  })

  it("shows the frame's resolution once it has loaded", () => {
    const socket = fakeSocket()
    render(<Preview stream="depth" socket={socket} />)
    sendFrame(socket, 'Zmlyc3Q=')

    const image = screen.getByRole('img')
    Object.defineProperties(image, { naturalWidth: { value: 480 }, naturalHeight: { value: 270 } })
    fireEvent.load(image)

    expect(screen.getByText('480 × 270')).toBeTruthy()
  })

  it('leaves its channel when unmounted', () => {
    const socket = fakeSocket()
    const { unmount } = render(<Preview stream="depth" socket={socket} />)

    unmount()

    expect(socket.fakeChannel.leave).toHaveBeenCalled()
  })
})
