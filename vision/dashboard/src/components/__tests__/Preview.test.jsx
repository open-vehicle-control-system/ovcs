import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, fireEvent, cleanup } from '@testing-library/react'
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

const sendFrame = (socket, bytes) => act(() => socket.handlers.frame(new Uint8Array(bytes).buffer))

describe('Preview', () => {
  let urls

  beforeEach(() => {
    urls = []
    // jsdom has no object URLs.
    URL.createObjectURL = vi.fn((blob) => {
      urls.push(blob)
      return `blob:frame-${urls.length}`
    })
    URL.revokeObjectURL = vi.fn()
  })

  afterEach(() => {
    cleanup()
    delete URL.createObjectURL
    delete URL.revokeObjectURL
  })

  it('renders the latest frame from its JPEG bytes', () => {
    const socket = fakeSocket()
    render(<Preview stream="left" socket={socket} />)

    expect(socket.channel).toHaveBeenCalledWith('preview:left', {})
    sendFrame(socket, [1])
    sendFrame(socket, [2, 3])

    expect(screen.getByRole('img', { name: 'left preview' }).getAttribute('src')).toBe('blob:frame-2')
    expect(urls[1].type).toBe('image/jpeg')
    expect(urls[1].size).toBe(2)
  })

  it('releases a frame once the next one replaces it, and the last one when unmounted', () => {
    const socket = fakeSocket()
    const { unmount } = render(<Preview stream="left" socket={socket} />)

    sendFrame(socket, [1])
    sendFrame(socket, [2])
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:frame-1')
    expect(URL.revokeObjectURL).not.toHaveBeenCalledWith('blob:frame-2')

    unmount()
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:frame-2')
  })

  it('acks a frame once the image has loaded or failed', () => {
    const socket = fakeSocket()
    render(<Preview stream="left" socket={socket} />)

    sendFrame(socket, [1])
    expect(socket.fakeChannel.push).not.toHaveBeenCalled()

    fireEvent.load(screen.getByRole('img'))
    expect(socket.fakeChannel.push).toHaveBeenCalledWith('ack', {})

    sendFrame(socket, [2])
    fireEvent.error(screen.getByRole('img'))
    expect(socket.fakeChannel.push).toHaveBeenCalledTimes(2)
  })

  it("shows the frame's resolution once it has loaded", () => {
    const socket = fakeSocket()
    render(<Preview stream="depth" socket={socket} />)
    sendFrame(socket, [1])

    const image = screen.getByRole('img')
    Object.defineProperties(image, { naturalWidth: { value: 480 }, naturalHeight: { value: 270 } })
    fireEvent.load(image)

    expect(screen.getByText('480 × 270')).toBeTruthy()
    expect(image.getAttribute('width')).toBe('480')
    expect(image.getAttribute('height')).toBe('270')
  })

  it('leaves its channel when unmounted', () => {
    const socket = fakeSocket()
    const { unmount } = render(<Preview stream="depth" socket={socket} />)

    unmount()

    expect(socket.fakeChannel.leave).toHaveBeenCalled()
  })
})
