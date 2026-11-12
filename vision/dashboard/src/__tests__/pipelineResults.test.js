import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useDetections, useSegmentations } from '../pipelineResults.js'

// A socket whose channels each keep their own handlers until `off`, so a test can deliver to one after it was left.
function fakeSocket() {
  const channels = []
  const channel = (topic) => {
    const handlers = {}
    const opened = {
      topic,
      on: (event, handler) => { handlers[event] = handler },
      off: (event) => { delete handlers[event] },
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
  const buffer = new ArrayBuffer(16 + ids.length)
  const view = new DataView(buffer)
  ;[4, 2, 0, 0, 4, 2, 2, 1].forEach((value, index) => view.setUint16(index * 2, value, true))
  new Uint8Array(buffer, 16).set(ids)
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
})
