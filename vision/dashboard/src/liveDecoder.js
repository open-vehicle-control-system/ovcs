import { codecOf, readVideoFrame } from './h264.js'

// Frames waiting in the decoder past this, it is behind: the stream skips to the next key frame.
export const MAX_DECODE_QUEUE = 8

const HARDWARE_PREFERENCES = ['prefer-hardware', 'no-preference']

/** Whether this browser offers WebCodecs' `VideoDecoder`, which it does only in a secure context. */
export const hasVideoDecoder = (scope = globalThis) => typeof scope.VideoDecoder === 'function'

/**
 * Decodes a camera's H.264 frames, as the `video:<camera>` channel pushes them, with WebCodecs and draws them on
 * `canvas`. It starts at the first key frame, configured from its sequence parameter set, on the hardware decoder
 * where the browser has one for the stream. Of the frames decoded since the last animation frame, it draws the newest
 * and closes the others undrawn. Each frame pushed is acked once taken (`onAck`); `onDrawn` gets the capture time, in
 * microseconds, and size of each frame drawn, and `onUnsupported` the codec of a stream the browser cannot decode.
 * After a decoder error, a configuration that fails, which drops the frames taken meanwhile, or while the decoder is
 * behind, it starts again at the next key frame.
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
    this.closed = false
    this.undrawn = null
    this.animationFrame = null
  }

  /** Takes one pushed frame: decoded, queued while the decoder is configured, or dropped until a key frame. */
  push(payload) {
    const frame = readVideoFrame(payload)
    this.take(frame)
    this.onAck()
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
    let config
    try {
      config = await this.supportedConfig(codec, frame)
    } catch {
      this.waiting = null
      return
    }
    if (this.closed) return
    const waiting = this.waiting
    this.waiting = null
    if (!config) {
      this.unsupported = true
      return this.onUnsupported(codec)
    }
    // A decoder that fails is closed: the next key frame opens another.
    const decoder = new this.scope.VideoDecoder({
      output: (decoded) => this.decoded(decoded),
      error: () => {
        if (this.decoder === decoder) this.decoder = null
      }
    })
    try {
      decoder.configure(config)
    } catch {
      return decoder.close()
    }
    this.decoder = decoder
    waiting.forEach((queued) => this.decode(queued))
  }

  // Without a `description`, the decoder takes the stream as Annex B, its parameter sets in band.
  async supportedConfig(codec, { width, height }) {
    for (const hardwareAcceleration of HARDWARE_PREFERENCES) {
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
