import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, fireEvent, cleanup } from '@testing-library/react'
import Preview from '../Preview.jsx'

function fakeSocket() {
  const handlers = {}
  const channel = {
    on: vi.fn((event, handler) => { handlers[event] = handler }),
    join: vi.fn(() => {
      const join = { receive: vi.fn((status, handler) => { handlers[`join/${status}`] = handler; return join }) }
      return join
    }),
    push: vi.fn(),
    off: vi.fn((event) => { delete handlers[event] }),
    onError: vi.fn((handler) => { handlers.error = handler }),
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

  it('shows its frame, overlays included, full screen from a button, and leaves it from the same one', () => {
    const frameOf = () => document.querySelector('[data-frame]')
    const request = vi.fn(function () {
      document.fullscreenElement = this
      fireEvent(document, new Event('fullscreenchange'))
      return Promise.resolve()
    })
    Element.prototype.requestFullscreen = request
    document.exitFullscreen = vi.fn(() => {
      document.fullscreenElement = null
      fireEvent(document, new Event('fullscreenchange'))
      return Promise.resolve()
    })
    try {
      const socket = fakeSocket()
      render(<Preview stream="left" socket={socket} overlay={<svg data-overlay />} />)
      sendFrame(socket, [1])
      const image = screen.getByRole('img', { name: 'left preview' })
      Object.defineProperties(image, { naturalWidth: { value: 640 }, naturalHeight: { value: 480 } })
      fireEvent.load(image)

      fireEvent.click(screen.getByRole('button', { name: 'Show left full screen' }))
      expect(request.mock.contexts[0]).toBe(frameOf())
      expect(frameOf().contains(document.querySelector('[data-overlay]'))).toBe(true)

      fireEvent.click(screen.getByRole('button', { name: 'Leave full screen' }))
      expect(document.exitFullscreen).toHaveBeenCalledTimes(1)
      expect(screen.getByRole('button', { name: 'Show left full screen' })).toBeTruthy()
    } finally {
      delete Element.prototype.requestFullscreen
      delete document.exitFullscreen
      delete document.fullscreenElement
    }
  })

  it('offers no full screen where the browser has none', () => {
    render(<Preview stream="left" socket={fakeSocket()} />)
    expect(screen.queryByRole('button', { name: /full screen/ })).toBeNull()
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

  it('drops its frame, released, and says it has none once its channel fails, as when the unit goes', () => {
    const socket = fakeSocket()
    render(<Preview stream="left" socket={socket} overlay={<span>boxes</span>} />)
    sendFrame(socket, [1])
    fireEvent.load(screen.getByRole('img'))

    act(() => socket.handlers.error())

    expect(screen.queryByRole('img')).toBeNull()
    expect(screen.queryByText('boxes')).toBeNull()
    expect(screen.getByText('No frame')).toBeTruthy()
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:frame-1')
  })

  it('says why the unit refuses its stream, until a join it accepts', () => {
    const socket = fakeSocket()
    render(<Preview stream="rear" socket={socket} />)

    act(() => socket.handlers['join/error']({ reason: 'unknown stream' }))
    expect(screen.getByText('The unit refuses this stream: unknown stream')).toBeTruthy()
    expect(screen.queryByText('No frame')).toBeNull()

    act(() => socket.handlers['join/ok']())
    expect(screen.getByText('No frame')).toBeTruthy()
  })

  describe('a video', () => {
    let animationFrames
    let decoders
    let supported

    // A key frame of a 2028 × 1520 stream as the video channel pushes it, captured at `captureUs`.
    const keyFrame = (captureUs) => {
      const units = [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x28, 0xac, 0, 0, 0, 1, 0x68, 0xeb, 0, 0, 0, 1, 0x65, 1]
      const bytes = new Uint8Array(13 + units.length)
      const view = new DataView(bytes.buffer)
      view.setUint8(0, 1)
      view.setBigInt64(1, BigInt(captureUs), true)
      view.setUint16(9, 2028, true)
      view.setUint16(11, 1520, true)
      bytes.set(units, 13)
      return bytes
    }
    const configured = () => act(() => new Promise((resolve) => setTimeout(resolve, 0)))

    beforeEach(() => {
      animationFrames = []
      decoders = []
      supported = true
      globalThis.VideoDecoder = class {
        static isConfigSupported = async (config) => ({ supported, config })
        state = 'unconfigured'
        decodeQueueSize = 0
        constructor({ output }) {
          this.output = output
          decoders.push(this)
        }
        configure() {
          this.state = 'configured'
        }
        decode() {}
        close() {
          this.state = 'closed'
        }
      }
      globalThis.EncodedVideoChunk = class {}
      vi.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => animationFrames.push(callback))
      vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation(() => ({ drawImage: vi.fn() }))
    })

    afterEach(() => {
      delete globalThis.VideoDecoder
      delete globalThis.EncodedVideoChunk
      delete globalThis.isSecureContext
      vi.restoreAllMocks()
    })

    it("decodes the camera's video channel on a canvas, not its JPEG preview, where the browser has WebCodecs", () => {
      const socket = fakeSocket()
      render(<Preview stream="center" socket={socket} video />)

      expect(socket.channel).toHaveBeenCalledWith('video:center', {})
      expect(socket.channel).not.toHaveBeenCalledWith('preview:center', {})
      expect(screen.getByLabelText('center video').tagName).toBe('CANVAS')
    })

    it('draws the overlays of the capture time of the frame drawn, and its size', async () => {
      const socket = fakeSocket()
      const overlay = vi.fn(() => <span>boxes</span>)
      render(<Preview stream="center" socket={socket} video overlay={overlay} />)
      sendFrame(socket, keyFrame(-5_000_000))
      await configured()

      act(() => decoders[0].output({ timestamp: -5_000_000, displayWidth: 2028, displayHeight: 1520, close: vi.fn() }))
      act(() => animationFrames.splice(0).forEach((callback) => callback()))

      expect(screen.getByText('boxes')).toBeTruthy()
      expect(overlay).toHaveBeenLastCalledWith(-5_000_000)
      expect(screen.getByText('2028 × 1520')).toBeTruthy()
    })

    it('says it waits for the video until its first frame is drawn', async () => {
      const socket = fakeSocket()
      render(<Preview stream="center" socket={socket} video />)
      expect(screen.getByText('Waiting for video')).toBeTruthy()

      sendFrame(socket, keyFrame(0))
      await configured()
      act(() => decoders[0].output({ timestamp: 0, displayWidth: 2028, displayHeight: 1520, close: vi.fn() }))
      act(() => animationFrames.splice(0).forEach((callback) => callback()))

      expect(screen.queryByText('Waiting for video')).toBeNull()
    })

    it('hides the frame drawn, its overlays too, and waits again once its channel fails', async () => {
      const socket = fakeSocket()
      render(<Preview stream="center" socket={socket} video overlay={() => <span>boxes</span>} />)
      sendFrame(socket, keyFrame(0))
      await configured()
      act(() => decoders[0].output({ timestamp: 0, displayWidth: 2028, displayHeight: 1520, close: vi.fn() }))
      act(() => animationFrames.splice(0).forEach((callback) => callback()))
      expect(screen.getByLabelText('center video').classList).not.toContain('invisible')

      act(() => socket.handlers.error())

      expect(screen.getByLabelText('center video').classList).toContain('invisible')
      expect(screen.queryByText('boxes')).toBeNull()
      expect(screen.getByText('Waiting for video')).toBeTruthy()
    })

    it('says why the unit refuses its video', () => {
      const socket = fakeSocket()
      render(<Preview stream="center" socket={socket} video />)

      act(() => socket.handlers['join/error']({ reason: 'unknown video' }))

      expect(screen.getByText('The unit refuses this stream: unknown video')).toBeTruthy()
    })

    it("shows nothing of the JPEG preview it replaces: neither its size, its overlays nor that a frame is shown", () => {
      const socket = fakeSocket()
      const { rerender } = render(<Preview stream="center" socket={socket} overlay={<span>boxes</span>} />)
      sendFrame(socket, [1])
      const image = screen.getByRole('img')
      Object.defineProperty(image, 'naturalWidth', { value: 640 })
      Object.defineProperty(image, 'naturalHeight', { value: 480 })
      fireEvent.load(image)
      expect(screen.getByText('boxes')).toBeTruthy()

      rerender(<Preview stream="center" socket={socket} video overlay={<span>boxes</span>} />)

      expect(screen.queryByText('boxes')).toBeNull()
      expect(document.querySelector('[data-resolution]')).toBeNull()
      expect(screen.getByText('Waiting for video')).toBeTruthy()
    })

    it('keeps hidden a frame decoded before its channel failed and drawn after, until the channel pushes again', async () => {
      const socket = fakeSocket()
      render(<Preview stream="center" socket={socket} video />)
      sendFrame(socket, keyFrame(0))
      await configured()
      const draw = () => act(() => animationFrames.splice(0).forEach((callback) => callback()))
      const output = (timestamp) => act(() => decoders[0].output({ timestamp, displayWidth: 2028, displayHeight: 1520, close: vi.fn() }))
      output(0)
      draw()

      output(33_333)
      act(() => socket.handlers.error())
      draw()
      expect(screen.getByLabelText('center video').classList).toContain('invisible')
      expect(screen.getByText('Waiting for video')).toBeTruthy()

      sendFrame(socket, keyFrame(1_000_000))
      output(1_000_000)
      draw()
      expect(screen.getByLabelText('center video').classList).not.toContain('invisible')
    })

    it('says the page is served over plain HTTP where the browser offers no WebCodecs for that, and joins nothing', () => {
      delete globalThis.VideoDecoder
      globalThis.isSecureContext = false
      const socket = fakeSocket()
      render(<Preview stream="center" socket={socket} video />)

      expect(socket.channel).not.toHaveBeenCalled()
      expect(screen.getByText(/served over plain HTTP/)).toBeTruthy()
    })

    it('says the browser cannot decode the stream where WebCodecs has no decoder for it', async () => {
      supported = false
      const socket = fakeSocket()
      render(<Preview stream="center" socket={socket} video />)
      sendFrame(socket, keyFrame(0))
      await configured()

      expect(screen.getByText(/cannot decode the camera's H.264 video/)).toBeTruthy()
      expect(screen.queryByText('Waiting for video')).toBeNull()
      expect(decoders).toEqual([])
      // Nothing takes the frames: the unit sends them no more.
      expect(socket.fakeChannel.leave).toHaveBeenCalledTimes(1)
    })
  })

  it('draws an overlay given as a function with the newest frame, a JPEG preview\'s capture time unknown', () => {
    const socket = fakeSocket()
    const overlay = vi.fn(() => <span>boxes</span>)
    render(<Preview stream="hq" socket={socket} overlay={overlay} />)
    sendFrame(socket, [1])
    const image = screen.getByRole('img')
    Object.defineProperties(image, { naturalWidth: { value: 4 }, naturalHeight: { value: 2 } })
    fireEvent.load(image)

    expect(screen.getByText('boxes')).toBeTruthy()
    expect(overlay).toHaveBeenLastCalledWith(null)
  })
})
