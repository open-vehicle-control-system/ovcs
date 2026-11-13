import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { resultAt, useDetectionResults, useDetections, useSegmentationResults, useSegmentations } from '../pipelineResults.js'

// A socket whose channels each keep their own handlers until `off`, so a test can deliver to one after it was left,
// and fail one as the unit stopping it does.
function fakeSocket() {
  const channels = []
  const channel = (topic) => {
    const handlers = {}
    const errorHandlers = []
    const opened = {
      topic,
      on: (event, handler) => { handlers[event] = handler },
      off: (event) => { delete handlers[event] },
      onError: (handler) => { errorHandlers.push(handler) },
      fail: () => act(() => errorHandlers.forEach((handler) => handler())),
      join: vi.fn(),
      leave: vi.fn(),
      push: vi.fn(),
      deliver: (event, payload) => act(() => handlers[event]?.(payload))
    }
    channels.push(opened)
    return opened
  }
  return { channel, channels }
}

const acks = (channel) => channel.push.mock.calls.filter(([event]) => event === 'ack').length

const person = { label: 'person', score: 0.62, distanceM: 1.84, outline: [[0.25, 0.2], [0.75, 0.2], [0.75, 0.8], [0.25, 0.8]] }

// A 2 × 1 grid of the classes `ids` over a whole 4 × 2 frame.
function grid(ids) {
  const buffer = new ArrayBuffer(24 + ids.length)
  const view = new DataView(buffer)
  ;[4, 2, 0, 0, 4, 2, 2, 1].forEach((value, index) => view.setUint16(index * 2, value, true))
  new Uint8Array(buffer, 24).set(ids)
  return buffer
}

describe('useDetections', () => {
  const outputs = [{ name: 'detections:objects', maxHz: 10, source: 'center' }]

  it("keeps each channel's latest result by topic", () => {
    const socket = fakeSocket()
    const { result } = renderHook(() => useDetections(socket, outputs))

    socket.channels[0].deliver('detections', { detections: [person] })

    expect(result.current).toEqual({ 'detections:objects': [person] })
  })

  it('hears nothing more from a channel it left', () => {
    const first = fakeSocket()
    const { result, rerender } = renderHook(({ socket }) => useDetections(socket, outputs), { initialProps: { socket: first } })

    rerender({ socket: fakeSocket() })
    first.channels[0].deliver('detections', { detections: [person] })

    expect(first.channels[0].leave).toHaveBeenCalled()
    expect(result.current).toEqual({})
  })

  it("drops a channel's result when the channel fails, until the next one", () => {
    const socket = fakeSocket()
    const { result } = renderHook(() => useDetections(socket, outputs))
    socket.channels[0].deliver('detections', { detections: [person] })

    socket.channels[0].fail()
    expect(result.current).toEqual({})

    socket.channels[0].deliver('detections', { detections: [] })
    expect(result.current).toEqual({ 'detections:objects': [] })
  })

  it('keeps a result when a channel it left fails', () => {
    const first = fakeSocket()
    const second = fakeSocket()
    const { result, rerender } = renderHook(({ socket }) => useDetections(socket, outputs), { initialProps: { socket: first } })
    rerender({ socket: second })
    second.channels[0].deliver('detections', { detections: [person] })

    first.channels[0].fail()

    expect(result.current).toEqual({ 'detections:objects': [person] })
  })

  describe('a result no other follows', () => {
    afterEach(() => vi.useRealTimers())

    const latestAfter = (maxHz, ms) => {
      vi.useFakeTimers()
      const socket = fakeSocket()
      const { result } = renderHook(() => useDetections(socket, [{ name: 'detections:objects', maxHz }]))
      socket.channels[0].deliver('detections', { detections: [person] })
      act(() => vi.advanceTimersByTime(ms))
      return result.current
    }

    it('is dropped after ten periods of its maxHz', () => {
      expect(latestAfter(2, 4999)).toEqual({ 'detections:objects': [person] })
      expect(latestAfter(2, 5000)).toEqual({})
    })

    it('is kept two seconds at least, and that long without a maxHz', () => {
      expect(latestAfter(10, 1999)).toEqual({ 'detections:objects': [person] })
      expect(latestAfter(10, 2000)).toEqual({})
      expect(latestAfter(null, 1999)).toEqual({ 'detections:objects': [person] })
      expect(latestAfter(null, 2000)).toEqual({})
    })

    it('is kept while others follow it in time', () => {
      vi.useFakeTimers()
      const socket = fakeSocket()
      const { result } = renderHook(() => useDetections(socket, outputs))

      socket.channels[0].deliver('detections', { detections: [person] })
      act(() => vi.advanceTimersByTime(1500))
      socket.channels[0].deliver('detections', { detections: [] })
      act(() => vi.advanceTimersByTime(1500))

      expect(result.current).toEqual({ 'detections:objects': [] })
    })
  })
})

describe('useSegmentations', () => {
  const outputs = [{ name: 'segmentation:scene', maxHz: 5, source: 'center' }]

  it('acks nothing on a new channel for a grid the one it left sends late', () => {
    const first = fakeSocket()
    const second = fakeSocket()
    const { result, rerender } = renderHook(({ socket }) => useSegmentations(socket, outputs), { initialProps: { socket: first } })

    rerender({ socket: second })
    first.channels[0].deliver('segmentation', grid([0, 1]))

    expect(result.current).toEqual({})
    expect(acks(second.channels[0])).toBe(0)
  })

  const classes = { labels: ['road', 'sky'], roadClasses: ['road'] }

  it("drops a channel's grid and classes when the channel fails, and acks the grid that follows its rejoin", () => {
    const socket = fakeSocket()
    const { result } = renderHook(() => useSegmentations(socket, outputs))
    const [channel] = socket.channels
    channel.deliver('classes', classes)
    channel.deliver('segmentation', grid([0, 1]))
    expect(acks(channel)).toBe(1)

    channel.fail()
    expect(result.current).toEqual({})

    channel.deliver('classes', classes)
    channel.deliver('segmentation', grid([0, 1]))
    expect(result.current['segmentation:scene'].segmentation.present).toEqual([0, 1])
    expect(acks(channel)).toBe(2)
  })

  it('drops a grid no other follows and the classes seen with it, and keeps the class names', () => {
    vi.useFakeTimers()
    try {
      const socket = fakeSocket()
      const { result } = renderHook(() => useSegmentations(socket, outputs))
      socket.channels[0].deliver('classes', classes)
      socket.channels[0].deliver('segmentation', grid([0, 1]))

      act(() => vi.advanceTimersByTime(1999))
      expect(result.current['segmentation:scene'].segmentation).toBeDefined()

      act(() => vi.advanceTimersByTime(1))
      expect(result.current).toEqual({ 'segmentation:scene': { classes } })
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('resultAt', () => {
  // A frame every 33.3 ms.
  const history = [
    { captureUs: 1_000_000, value: 'a' },
    { captureUs: 1_033_333, value: 'b' },
    { captureUs: 1_066_666, value: 'c' }
  ]

  it('is the newest result of a frame captured no later than the one given', () => {
    expect(resultAt(history, 1_050_000)).toBe('b')
    expect(resultAt(history, 1_066_666)).toBe('c')
    expect(resultAt(history, 2_000_000)).toBe('c')
  })

  it("takes a result of the same frame stamped a little after it, each output's time read on its own", () => {
    expect(resultAt(history, 1_033_320)).toBe('b')
    expect(resultAt([{ captureUs: 1_033_333, value: 'next frame' }], 1_000_000)).toBeNull()
  })

  it('is none for a frame captured before every result', () => {
    expect(resultAt(history, 900_000)).toBeNull()
    expect(resultAt([], 900_000)).toBeNull()
  })
})

describe('result histories', () => {
  const detectionOutputs = [{ name: 'detections:objects', maxHz: 10, source: 'center' }]
  const segmentationOutputs = [{ name: 'segmentation:road', maxHz: 5, source: 'center' }]

  it("keeps each detection result by its frame's capture time, the last three seconds of them", () => {
    const socket = fakeSocket()
    const { result } = renderHook(() => useDetectionResults(socket, detectionOutputs))

    for (const captureUs of [0, 1_000_000, 2_000_000, 3_500_000]) socket.channels[0].deliver('detections', { captureUs, detections: [person] })

    expect(result.current.latest).toEqual({ 'detections:objects': [person] })
    expect(result.current.history.current['detections:objects'].map(({ captureUs }) => captureUs)).toEqual([1_000_000, 2_000_000, 3_500_000])
  })

  it("keeps each segmentation grid by its frame's capture time", () => {
    const socket = fakeSocket()
    const { result } = renderHook(() => useSegmentationResults(socket, segmentationOutputs))

    socket.channels[0].deliver('segmentation', grid([0, 13]))

    const [entry] = result.current.history.current['segmentation:road']
    expect(entry.captureUs).toBe(0)
    expect(entry.value.present).toEqual([0, 13])
  })
})
