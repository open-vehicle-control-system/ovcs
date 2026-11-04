import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { useMetrics } from '../metrics.js'

const speed = { module: 'Elixir.Motion', key: 'speed' }
const rpm = { module: 'Elixir.Motion', key: 'rpm' }

// A Phoenix socket whose one channel records its pushes and lets the test join, rejoin and push updates.
const fakeSocket = () => {
  const handlers = {}
  const joined = []
  const channel = {
    on: vi.fn((event, callback) => (handlers[event] = callback)),
    onError: vi.fn((callback) => (handlers.error = callback)),
    onClose: vi.fn((callback) => (handlers.close = callback)),
    join: vi.fn(() => {
      const join = { receive: (status, callback) => (status === 'ok' && joined.push(callback), join) }
      return join
    }),
    push: vi.fn(),
    leave: vi.fn()
  }
  return {
    channel: vi.fn(() => channel),
    pushes: () => channel.push.mock.calls,
    join: () => joined.forEach((callback) => callback()),
    drop: () => handlers.error(),
    update: (payload) => handlers.updated(payload),
    raw: channel
  }
}

describe('metrics store', () => {
  let socket
  let stop
  const undos = []
  const watch = (metrics) => undos.push(useMetrics.getState().watch(metrics))

  beforeEach(() => {
    useMetrics.setState({ data: {}, units: {} })
    socket = fakeSocket()
  })

  afterEach(() => {
    undos.splice(0).forEach((undo) => undo())
    stop?.()
    stop = null
  })

  it('joins metrics with the refresh interval', () => {
    stop = useMetrics.getState().listen(socket, 70)
    expect(socket.channel).toHaveBeenCalledWith('metrics', { interval: 70 })
  })

  it('replaces values and units on each push', () => {
    stop = useMetrics.getState().listen(socket, 70)
    socket.update({ data: { 'Elixir.Motion': { speed: 1, rpm: 2 } }, units: { 'Elixir.Motion': { speed: 'km/h' } } })
    socket.update({ data: { 'Elixir.Motion': { speed: 3 } }, units: {} })

    expect(useMetrics.getState().data).toEqual({ 'Elixir.Motion': { speed: 3 } })
    expect(useMetrics.getState().units).toEqual({})
  })

  it('subscribes a metric once however many watch it', () => {
    stop = useMetrics.getState().listen(socket, 70)
    socket.join()
    const first = useMetrics.getState().watch([speed])
    const second = useMetrics.getState().watch([speed, rpm])
    expect(socket.pushes()).toEqual([
      ['subscribe', speed],
      ['subscribe', rpm]
    ])

    first()
    expect(socket.pushes()).toHaveLength(2)
    second()
    expect(socket.pushes().slice(2)).toEqual([
      ['unsubscribe', speed],
      ['unsubscribe', rpm]
    ])
  })

  it('subscribes what was watched before the join, on the join', () => {
    watch([speed])
    stop = useMetrics.getState().listen(socket, 70)
    expect(socket.pushes()).toEqual([])

    socket.join()
    expect(socket.pushes()).toEqual([['subscribe', speed]])
  })

  it('subscribes again on a rejoin', () => {
    stop = useMetrics.getState().listen(socket, 70)
    socket.join()
    watch([speed, rpm])
    socket.raw.push.mockClear()

    socket.drop()
    socket.join()
    expect(socket.pushes()).toEqual([
      ['subscribe', speed],
      ['subscribe', rpm]
    ])
  })

  it('pushes nothing while the channel is down; the rejoin subscribes what is watched then', () => {
    stop = useMetrics.getState().listen(socket, 70)
    socket.join()
    const undo = useMetrics.getState().watch([speed])
    socket.drop()
    socket.raw.push.mockClear()

    undo()
    watch([rpm])
    expect(socket.pushes()).toEqual([])

    socket.join()
    expect(socket.pushes()).toEqual([['subscribe', rpm]])
  })

  it('leaves the channel when stopped', () => {
    useMetrics.getState().listen(socket, 70)()
    expect(socket.raw.leave).toHaveBeenCalled()
  })
})
