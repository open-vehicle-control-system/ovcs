import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useConnection } from '../connection.js'

const fakeSocket = () => {
  const callbacks = {}
  return {
    callbacks,
    onOpen: vi.fn((callback) => ((callbacks.open = callback), 'r1')),
    onClose: vi.fn((callback) => ((callbacks.close = callback), 'r2')),
    onError: vi.fn((callback) => ((callbacks.error = callback), 'r3')),
    off: vi.fn(),
    isConnected: vi.fn(() => false)
  }
}

describe('connection store', () => {
  beforeEach(() => useConnection.setState({ state: 'connecting' }))

  it("follows the socket's opening, closing and errors", () => {
    const socket = fakeSocket()
    useConnection.getState().watch(socket)
    expect(useConnection.getState().state).toBe('connecting')

    socket.callbacks.open()
    expect(useConnection.getState().state).toBe('connected')
    socket.callbacks.close()
    expect(useConnection.getState().state).toBe('disconnected')
    socket.callbacks.open()
    socket.callbacks.error()
    expect(useConnection.getState().state).toBe('disconnected')
  })

  it('starts connected when the socket opened before it was watched', () => {
    const socket = fakeSocket()
    socket.isConnected.mockReturnValue(true)
    useConnection.getState().watch(socket)
    expect(useConnection.getState().state).toBe('connected')
  })

  it('stops following the socket when undone', () => {
    const socket = fakeSocket()
    useConnection.getState().watch(socket)()
    expect(socket.off).toHaveBeenCalledWith(['r1', 'r2', 'r3'])
  })
})
