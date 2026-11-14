import { describe, it, expect, vi } from 'vitest'

const sockets = vi.hoisted(() => [])
vi.mock('phoenix', () => ({
  Socket: class {
    constructor(url, options) {
      this.url = url
      this.options = options
      this.connect = vi.fn()
      sockets.push(this)
    }
  }
}))

describe('the dashboard socket', () => {
  it('connects with a heartbeat every few seconds, so a link gone without closing is noticed in seconds', async () => {
    const { HEARTBEAT_MS } = await import('../socket.js')

    expect(HEARTBEAT_MS).toBeLessThanOrEqual(5000)
    expect(sockets).toHaveLength(1)
    expect(sockets[0].options).toEqual({ heartbeatIntervalMs: HEARTBEAT_MS })
    expect(sockets[0].connect).toHaveBeenCalled()
  })
})
