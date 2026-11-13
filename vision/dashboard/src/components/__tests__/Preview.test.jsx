import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, fireEvent, cleanup } from '@testing-library/react'
import Preview from '../Preview.jsx'

function fakeSocket() {
  const handlers = {}
  const channel = {
    on: vi.fn((event, handler) => { handlers[event] = handler }),
    join: vi.fn(() => ({ receive: vi.fn() })),
    push: vi.fn(),
    off: vi.fn((event) => { delete handlers[event] }),
    leave: vi.fn()
  }
  return { channel: vi.fn(() => channel), handlers, fakeChannel: channel }
}

// As phoenix.js, a frame reaches the handler bound at the time it arrives, if any.
const sendFrame = (socket, bytes) => act(() => socket.handlers.frame?.(new Uint8Array(bytes).buffer))

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

  it('drops a frame that arrives while leaving, so no object URL outlives it', () => {
    const socket = fakeSocket()
    const { unmount } = render(<Preview stream="left" socket={socket} />)
    sendFrame(socket, [1])

    unmount()
    sendFrame(socket, [2])

    expect(URL.createObjectURL).toHaveBeenCalledTimes(1)
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:frame-1')
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

  it("gives the frame's cell its image's size once it has loaded, for classes that shape the frame and its aside", () => {
    const socket = fakeSocket()
    render(<Preview stream="depth" socket={socket} cellClassName="cell" frameClassName="shaped" />)
    const frame = () => document.querySelector('[data-frame]')
    const cell = () => frame().parentElement

    expect(cell().className).toBe('cell')
    expect(cell().parentElement.tagName).toBe('FIGURE')
    expect(cell().style.getPropertyValue('--frame-width')).toBe('')
    expect(frame().className.split(' ')).toContain('shaped')
    expect(frame().className.split(' ')).not.toContain('aspect-video')

    sendFrame(socket, [1])
    const image = screen.getByRole('img')
    Object.defineProperties(image, { naturalWidth: { value: 640 }, naturalHeight: { value: 480 } })
    fireEvent.load(image)

    expect(frame().contains(image)).toBe(true)
    expect([cell().style.getPropertyValue('--frame-width'), cell().style.getPropertyValue('--frame-height')]).toEqual(['640', '480'])
  })

  it('keeps its aside next to the frame in its cell when beside, an empty track after the caption', () => {
    render(<Preview stream="depth" socket={fakeSocket()} aside={<span>scale</span>} asideBeside asideClassName="narrow" />)
    const frame = document.querySelector('[data-frame]')
    const aside = document.querySelector('[data-aside]')

    expect(aside.parentElement).toBe(frame.parentElement)
    expect(aside.previousElementSibling).toBe(frame)
    expect(aside.className.split(' ')).toContain('narrow')
    expect(aside.textContent).toBe('scale')
    const figure = document.querySelector('figure')
    expect(figure.lastElementChild.hasAttribute('data-aside-track')).toBe(true)
    expect(figure.lastElementChild.childElementCount).toBe(0)
  })

  it('keeps a 16:9 frame unless told otherwise', () => {
    render(<Preview stream="left" socket={fakeSocket()} />)

    expect(document.querySelector('[data-frame]').className.split(' ')).toContain('aspect-video')
  })

  it('hands its channel over before joining, so the events bound on it miss no push', () => {
    const socket = fakeSocket()
    const onChannel = vi.fn()
    render(<Preview stream="depth" socket={socket} onChannel={onChannel} />)

    expect(onChannel).toHaveBeenCalledWith(socket.fakeChannel)
    expect(onChannel.mock.invocationCallOrder[0]).toBeLessThan(socket.fakeChannel.join.mock.invocationCallOrder[0])
  })

  it('leaves its channel when unmounted', () => {
    const socket = fakeSocket()
    const { unmount } = render(<Preview stream="depth" socket={socket} />)

    unmount()

    expect(socket.fakeChannel.leave).toHaveBeenCalled()
  })
})
