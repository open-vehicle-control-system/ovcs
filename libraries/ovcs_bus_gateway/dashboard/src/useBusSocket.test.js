import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'

import { useBusSocket } from './useBusSocket'

const phoenix = vi.hoisted(() => {
  const sockets = []

  class Channel {
    handlers = {}
    joined = false
    left = false
    on(event, handler) {
      this.handlers[event] = handler
    }
    onClose(handler) {
      this.handlers.close = handler
    }
    join() {
      this.joined = true
    }
    leave() {
      this.left = true
      this.handlers.close?.()
    }
  }

  class Socket {
    channels = []
    handlers = {}
    connect = vi.fn()
    disconnect = vi.fn()
    constructor(path) {
      this.path = path
      sockets.push(this)
    }
    onError(handler) {
      this.handlers.error = handler
    }
    onClose(handler) {
      this.handlers.close = handler
    }
    channel(topic) {
      const channel = new Channel()
      channel.topic = topic
      this.channels.push(channel)
      return channel
    }
  }

  return { sockets, Socket }
})

vi.mock('phoenix', () => ({ Socket: phoenix.Socket }))

const sig = (value, changedAt = 1000) => ({
  node: 'vms', source: 'A', name: 'speed', value, unit: null, changedAt, publishedAt: changedAt, stale: false
})

const socket = () => phoenix.sockets.at(-1)
const channel = () => socket().channels.at(-1)

describe('useBusSocket', () => {
  beforeEach(() => {
    phoenix.sockets.length = 0
    vi.useFakeTimers()
  })
  afterEach(() => vi.useRealTimers())

  test('joins the signals channel over /sockets/dashboard and is live from the first snapshot', () => {
    const { result } = renderHook(() => useBusSocket())
    expect(socket().path).toBe('/sockets/dashboard')
    expect(socket().connect).toHaveBeenCalled()
    expect(channel().topic).toBe('signals')
    expect(channel().joined).toBe(true)
    expect(result.current.status).toBe('connecting')

    act(() => channel().handlers.snapshot({ signals: [sig(1)] }))
    expect(result.current.status).toBe('live')
    expect(result.current.signals.get('vms/A/speed').value).toBe(1)
  })

  test('merges updates, stamping when a change was seen', () => {
    vi.setSystemTime(50_000)
    const { result } = renderHook(() => useBusSocket())
    act(() => channel().handlers.snapshot({ signals: [sig(1)] }))
    act(() => channel().handlers.update({ signals: [sig(2, 2000)] }))
    expect(result.current.signals.get('vms/A/speed')).toMatchObject({ value: 2, changeSeenAt: 50_000 })
  })

  test('is disconnected while the socket is down, and connecting while the gateway is overloaded', () => {
    const { result } = renderHook(() => useBusSocket())
    act(() => socket().handlers.error())
    expect(result.current.status).toBe('disconnected')
    act(() => channel().handlers.overloaded())
    expect(result.current.status).toBe('connecting')
  })

  test('joins again a second after the gateway stops the channel', () => {
    renderHook(() => useBusSocket())
    act(() => channel().handlers.close())
    expect(socket().channels).toHaveLength(1)
    act(() => vi.advanceTimersByTime(1000))
    expect(socket().channels).toHaveLength(2)
    expect(channel().joined).toBe(true)
  })

  test('leaves the channel and disconnects on unmount, without joining again', () => {
    const { unmount } = renderHook(() => useBusSocket())
    const joined = channel()
    unmount()
    expect(joined.left).toBe(true)
    expect(socket().disconnect).toHaveBeenCalled()
    vi.advanceTimersByTime(5000)
    expect(socket().channels).toHaveLength(1)
  })
})
