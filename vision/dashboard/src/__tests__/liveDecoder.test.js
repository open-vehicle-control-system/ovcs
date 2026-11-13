import { describe, expect, it, vi } from 'vitest'
import { LiveDecoder, MAX_DECODE_QUEUE, hasVideoDecoder } from '../liveDecoder.js'

const SPS = [0x67, 0x64, 0x00, 0x28, 0xac]
const PPS = [0x68, 0xeb]

// A frame as the video channel pushes it.
function payload({ key, captureUs, units }) {
  const data = units.flatMap((unit) => [0, 0, 0, 1, ...unit])
  const bytes = new Uint8Array(13 + data.length)
  const view = new DataView(bytes.buffer)
  view.setUint8(0, key ? 1 : 0)
  view.setBigInt64(1, BigInt(captureUs), true)
  view.setUint16(9, 2028, true)
  view.setUint16(11, 1520, true)
  bytes.set(data, 13)
  return bytes.buffer
}

const keyFrame = (captureUs) => payload({ key: true, captureUs, units: [SPS, PPS, [0x65, 1]] })
const deltaFrame = (captureUs) => payload({ key: false, captureUs, units: [[0x41, 2]] })

// A WebCodecs scope whose decoders record what they are given and output or fail when told, and whose animation
// frames run when told.
function fakeScope({ supported = () => true } = {}) {
  const decoders = []
  const animationFrames = []
  class FakeVideoDecoder {
    static isConfigSupported = vi.fn(async (config) => ({ supported: supported(config), config }))
    state = 'unconfigured'
    decodeQueueSize = 0
    chunks = []
    constructor({ output, error }) {
      this.output = output
      this.error = error
      decoders.push(this)
    }
    configure(config) {
      this.config = config
      this.state = 'configured'
    }
    decode(chunk) {
      this.chunks.push(chunk)
    }
    close() {
      this.state = 'closed'
    }
    emit(timestamp) {
      const frame = { timestamp, displayWidth: 2028, displayHeight: 1520, close: vi.fn() }
      this.output(frame)
      return frame
    }
    fail() {
      this.state = 'closed'
      this.error(new Error('decode failed'))
    }
  }
  class FakeEncodedVideoChunk {
    constructor(init) {
      Object.assign(this, init)
    }
  }
  return {
    VideoDecoder: FakeVideoDecoder,
    EncodedVideoChunk: FakeEncodedVideoChunk,
    requestAnimationFrame: (callback) => animationFrames.push(callback),
    cancelAnimationFrame: vi.fn(),
    decoders,
    runAnimationFrames: () => animationFrames.splice(0).forEach((callback) => callback()),
    animationFrames
  }
}

function fakeCanvas() {
  const context = { drawImage: vi.fn() }
  return { width: 0, height: 0, context, getContext: () => context }
}

function start(scopeOptions) {
  const scope = fakeScope(scopeOptions)
  const canvas = fakeCanvas()
  const callbacks = { onAck: vi.fn(), onDrawn: vi.fn(), onUnsupported: vi.fn() }
  const live = new LiveDecoder(canvas, { ...callbacks, scope })
  return { scope, canvas, live, ...callbacks }
}

// Lets the decoder's configuration, which waits for the browser's answer, finish.
const configured = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('hasVideoDecoder', () => {
  it('is whether the browser offers WebCodecs, which it does only in a secure context', () => {
    expect(hasVideoDecoder(fakeScope())).toBe(true)
    expect(hasVideoDecoder({})).toBe(false)
  })
})

describe('LiveDecoder', () => {
  it('acks and drops the frames before the first key frame', () => {
    const { scope, live, onAck } = start()

    live.push(deltaFrame(0))

    expect(onAck).toHaveBeenCalledTimes(1)
    expect(scope.decoders).toEqual([])
  })

  it("decodes from the first key frame, configured for its codec and size, as Annex B, preferring hardware", async () => {
    const { scope, live } = start()

    live.push(keyFrame(-1_000_000))
    await configured()

    const [decoder] = scope.decoders
    expect(decoder.config).toEqual({
      codec: 'avc1.640028',
      codedWidth: 2028,
      codedHeight: 1520,
      hardwareAcceleration: 'prefer-hardware',
      optimizeForLatency: true
    })
    expect(decoder.chunks).toHaveLength(1)
    expect(decoder.chunks[0]).toMatchObject({ type: 'key', timestamp: -1_000_000 })
    expect([...decoder.chunks[0].data.subarray(0, 5)]).toEqual([0, 0, 0, 1, 0x67])
  })

  it('decodes without hardware acceleration where the browser has none for the stream', async () => {
    const { scope, live } = start({ supported: (config) => config.hardwareAcceleration !== 'prefer-hardware' })

    live.push(keyFrame(0))
    await configured()

    expect(scope.decoders[0].config.hardwareAcceleration).toBe('no-preference')
  })

  it('decodes the frames that come while the decoder is configured, in order, and acks each frame once', async () => {
    const { scope, live, onAck } = start()

    live.push(keyFrame(0))
    live.push(deltaFrame(33_333))
    await configured()
    live.push(deltaFrame(66_666))

    expect(scope.decoders[0].chunks.map(({ type, timestamp }) => [type, timestamp])).toEqual([
      ['key', 0],
      ['delta', 33_333],
      ['delta', 66_666]
    ])
    expect(onAck).toHaveBeenCalledTimes(3)
  })

  it('says when the browser cannot decode the stream, and acks the frames it then drops', async () => {
    const { scope, live, onAck, onUnsupported } = start({ supported: () => false })

    live.push(keyFrame(0))
    await configured()
    live.push(deltaFrame(33_333))

    expect(onUnsupported).toHaveBeenCalledWith('avc1.640028')
    expect(scope.decoders).toEqual([])
    expect(onAck).toHaveBeenCalledTimes(2)
  })

  it('draws the newest decoded frame at the next animation frame, the late ones closed undrawn', async () => {
    const { scope, canvas, live, onDrawn } = start()
    live.push(keyFrame(0))
    await configured()
    const [decoder] = scope.decoders

    const late = decoder.emit(0)
    const newest = decoder.emit(33_333)
    scope.runAnimationFrames()

    expect(late.close).toHaveBeenCalled()
    expect(canvas.context.drawImage).toHaveBeenCalledTimes(1)
    expect(canvas.context.drawImage).toHaveBeenCalledWith(newest, 0, 0, 2028, 1520)
    expect(newest.close).toHaveBeenCalled()
    expect([canvas.width, canvas.height]).toEqual([2028, 1520])
    expect(onDrawn).toHaveBeenCalledWith(33_333, { width: 2028, height: 1520 })
  })

  it('starts again at the next key frame after a decoder error', async () => {
    const { scope, live, onAck } = start()
    live.push(keyFrame(0))
    await configured()

    scope.decoders[0].fail()
    live.push(deltaFrame(33_333))
    live.push(keyFrame(1_000_000))
    await configured()

    expect(scope.decoders).toHaveLength(2)
    expect(scope.decoders[1].chunks.map(({ timestamp }) => timestamp)).toEqual([1_000_000])
    expect(onAck).toHaveBeenCalledTimes(3)
  })

  it('drops the frames taken while the configuration check fails, and starts again at the next key frame', async () => {
    const { scope, live, onAck } = start()
    scope.VideoDecoder.isConfigSupported.mockRejectedValueOnce(new TypeError('invalid codec'))

    live.push(keyFrame(0))
    live.push(deltaFrame(33_333))
    await configured()
    live.push(deltaFrame(66_666))
    live.push(keyFrame(1_000_000))
    await configured()

    expect(scope.decoders).toHaveLength(1)
    expect(scope.decoders[0].chunks.map(({ timestamp }) => timestamp)).toEqual([1_000_000])
    expect(onAck).toHaveBeenCalledTimes(4)
  })

  it('closes a decoder whose configuration throws, and starts again at the next key frame', async () => {
    const { scope, live } = start()
    vi.spyOn(scope.VideoDecoder.prototype, 'configure').mockImplementationOnce(() => {
      throw new TypeError('invalid configuration')
    })

    live.push(keyFrame(0))
    live.push(deltaFrame(33_333))
    await configured()
    live.push(deltaFrame(66_666))
    live.push(keyFrame(1_000_000))
    await configured()

    expect(scope.decoders).toHaveLength(2)
    expect(scope.decoders[0].state).toBe('closed')
    expect(scope.decoders[0].chunks).toEqual([])
    expect(scope.decoders[1].chunks.map(({ timestamp }) => timestamp)).toEqual([1_000_000])
  })

  it('skips to the next key frame while the decoder falls behind', async () => {
    const { scope, live } = start()
    live.push(keyFrame(0))
    await configured()
    const [decoder] = scope.decoders

    decoder.decodeQueueSize = MAX_DECODE_QUEUE + 1
    live.push(deltaFrame(33_333))
    decoder.decodeQueueSize = 0
    live.push(deltaFrame(66_666))
    live.push(keyFrame(1_000_000))
    await configured()

    expect(scope.decoders.flatMap(({ chunks }) => chunks.map(({ timestamp }) => timestamp))).toEqual([0, 1_000_000])
  })

  it('closes its decoder and the frame waiting to be drawn, and draws nothing after', async () => {
    const { scope, canvas, live } = start()
    live.push(keyFrame(0))
    await configured()
    const [decoder] = scope.decoders
    const waiting = decoder.emit(0)

    live.close()
    scope.runAnimationFrames()

    expect(decoder.state).toBe('closed')
    expect(waiting.close).toHaveBeenCalled()
    expect(canvas.context.drawImage).not.toHaveBeenCalled()
  })
})
