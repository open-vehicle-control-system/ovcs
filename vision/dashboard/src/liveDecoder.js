import { codecOf, readVideoFrame } from './h264.js'

// Frames waiting in the decoder past this, it is behind: the stream skips to the next key frame.
export const MAX_DECODE_QUEUE = 8

const HARDWARE_PREFERENCES = ['prefer-hardware', 'no-preference']

// Decoders failing in a row, with no frame decoded between them, past this, the stream is one the browser cannot decode.
export const MAX_FAILURES = 3

/** Whether this browser offers WebCodecs' `VideoDecoder`, which it does only in a secure context. */
export const hasVideoDecoder = (scope = globalThis) => typeof scope.VideoDecoder === 'function'

/**
 * Decodes a camera's H.264 frames, as the `video:<camera>` channel pushes them, with WebCodecs and draws them on
 * `canvas`. It starts at the first key frame, configured from its sequence parameter set, on the hardware decoder
 * where the browser has one for the stream. Of the frames decoded since the last animation frame, it draws the newest
 * and closes the others undrawn. Each frame pushed is acked once taken (`onAck`), one it cannot read or decode
 * included, which it drops; `onDrawn` gets the capture time, in microseconds, and size of each frame drawn, and
 * `onUnsupported` the codec of a stream the browser cannot decode. After a decoder error, a frame the decoder
 * refuses, a configuration that fails, which drops the frames taken meanwhile, or while the decoder is behind, it
 * starts again at the next key frame. Once a decoder failed, the next ones do not prefer hardware; `MAX_FAILURES` of
 * them failing in a row, with no frame decoded between them, the stream is one the browser cannot decode.
 */
export class LiveDecoder {
  constructor(canvas, { onAck = () => {}, onDrawn = () => {}, onUnsupported = () => {}, scope = globalThis } = {}) {
    this.canvas = canvas
    this.context = canvas.getContext('2d')
    this.onAck = onAck
    this.onDrawn = onDrawn
    this.onUnsupported = onUnsupported
    this.scope = scope
    this.decoder = null
    // The frames taken while the decoder is configured, decoded once it is.
    this.waiting = null
    this.unsupported = false
    // The decoders that failed since the last frame decoded.
    this.failures = 0
    // Whether a decoder failed: the next ones leave the choice of hardware to the browser.
    this.hardwareFailed = false
    this.closed = false
    this.undrawn = null
    this.animationFrame = null
  }

  /** Takes one pushed frame: decoded, queued while the decoder is configured, or dropped until a key frame. */
  push(payload) {
    let frame = null
    try {
      frame = readVideoFrame(payload)
      this.take(frame)
    } catch {
      // A frame that cannot be read is dropped; one the decoder refuses fails that decoder.
      if (frame) this.failed(this.decoder)
    } finally {
      this.onAck()
    }
  }

  close() {
    this.closed = true
    this.closeDecoder()
    this.undrawn?.close()
    this.undrawn = null
    if (this.animationFrame !== null) this.scope.cancelAnimationFrame(this.animationFrame)
  }

  take(frame) {
    if (this.closed || this.unsupported) return
    if (this.waiting) return this.waiting.push(frame)
    if (this.decoder?.state === 'configured' && this.decoder.decodeQueueSize <= MAX_DECODE_QUEUE) return this.decode(frame)
    this.closeDecoder()
    const codec = frame.key ? codecOf(frame.data) : null
    if (codec) this.open(codec, frame)
  }

  async open(codec, frame) {
    this.waiting = [frame]
    let decoder = null
    try {
      const config = await this.supportedConfig(codec, frame)
      if (this.closed) return
      const waiting = this.waiting
      this.waiting = null
      if (!config) return this.giveUp(codec)
      // A decoder that fails is closed: the next key frame opens another.
      decoder = new this.scope.VideoDecoder({
        output: (decoded) => this.decoded(decoded),
        error: () => this.failed(decoder, codec)
      })
      decoder.configure(config)
      this.decoder = decoder
      waiting.forEach((queued) => this.decode(queued))
    } catch {
      this.waiting = null
      if (decoder) this.failed(decoder, codec)
    }
  }

  // `decoder` failed: closed, and the stream given up once too many did in a row.
  failed(decoder, codec) {
    if (!decoder) return
    if (decoder.state !== 'closed') decoder.close()
    if (this.decoder === decoder) this.decoder = null
    this.failures += 1
    this.hardwareFailed = true
    if (codec && this.failures >= MAX_FAILURES) this.giveUp(codec)
  }

  giveUp(codec) {
    this.unsupported = true
    this.onUnsupported(codec)
  }

  // Without a `description`, the decoder takes the stream as Annex B, its parameter sets in band.
  async supportedConfig(codec, { width, height }) {
    for (const hardwareAcceleration of HARDWARE_PREFERENCES.slice(this.hardwareFailed ? 1 : 0)) {
      const config = { codec, codedWidth: width, codedHeight: height, hardwareAcceleration, optimizeForLatency: true }
      const { supported } = await this.scope.VideoDecoder.isConfigSupported(config)
      if (supported) return config
    }
    return null
  }

  decode(frame) {
    const chunk = new this.scope.EncodedVideoChunk({
      type: frame.key ? 'key' : 'delta',
      timestamp: frame.captureUs,
      data: frame.data
    })
    this.decoder.decode(chunk)
  }

  closeDecoder() {
    if (this.decoder && this.decoder.state !== 'closed') this.decoder.close()
    this.decoder = null
  }

  decoded(videoFrame) {
    if (this.closed) return videoFrame.close()
    this.failures = 0
    this.undrawn?.close()
    this.undrawn = videoFrame
    if (this.animationFrame === null) this.animationFrame = this.scope.requestAnimationFrame(() => this.draw())
  }

  draw() {
    this.animationFrame = null
    const videoFrame = this.undrawn
    this.undrawn = null
    if (!videoFrame || this.closed) return
    const { displayWidth: width, displayHeight: height, timestamp } = videoFrame
    if (this.canvas.width !== width) this.canvas.width = width
    if (this.canvas.height !== height) this.canvas.height = height
    this.context.drawImage(videoFrame, 0, 0, width, height)
    videoFrame.close()
    this.onDrawn(timestamp, { width, height })
  }
}
