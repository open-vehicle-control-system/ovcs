import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { STALE_MS, useStatus } from '../status.js'

// A status channel that keeps its handlers, so a test pushes a status, fails it or answers its join.
function fakeChannel() {
  const handlers = {}
  const join = { receive: vi.fn((status, handler) => { handlers[`join/${status}`] = handler; return join }) }
  const channel = {
    on: vi.fn((event, handler) => { handlers[event] = handler }),
    onError: vi.fn((handler) => { handlers.error = handler }),
    join: vi.fn(() => join),
    leave: vi.fn()
  }
  return { socket: { channel: () => channel }, handlers, channel }
}

describe('status store', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    useStatus.setState({ snapshot: null, joins: 0 })
  })

  afterEach(() => vi.useRealTimers())

  it("counts the status channel's joins, a rejoin after the unit comes back included", () => {
    const { socket, handlers } = fakeChannel()
    useStatus.getState().listen(socket)
    expect(useStatus.getState().joins).toBe(0)

    handlers['join/ok']()
    handlers['join/ok']()

    expect(useStatus.getState().joins).toBe(2)
  })

  it('has no snapshot once its channel fails, as when the socket closes', () => {
    const { socket, handlers } = fakeChannel()
    useStatus.getState().listen(socket)
    handlers.status({ depthHz: 30 })
    expect(useStatus.getState().snapshot).toEqual({ depthHz: 30 })

    handlers.error()

    expect(useStatus.getState().snapshot).toBeNull()
  })

  it('has no snapshot once none came for STALE_MS, and keeps it while they follow each other', () => {
    const { socket, handlers } = fakeChannel()
    useStatus.getState().listen(socket)

    handlers.status({ depthHz: 30 })
    vi.advanceTimersByTime(STALE_MS - 1)
    handlers.status({ depthHz: 29 })
    vi.advanceTimersByTime(STALE_MS - 1)
    expect(useStatus.getState().snapshot).toEqual({ depthHz: 29 })

    vi.advanceTimersByTime(1)
    expect(useStatus.getState().snapshot).toBeNull()
  })

  it('leaves its channel and waits for no status once unlistened', () => {
    const { socket, handlers, channel } = fakeChannel()
    const unlisten = useStatus.getState().listen(socket)
    handlers.status({ depthHz: 30 })

    unlisten()

    expect(channel.leave).toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })
})
