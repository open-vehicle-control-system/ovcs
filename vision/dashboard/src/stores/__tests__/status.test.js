import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useStatus } from '../status.js'

describe('status store', () => {
  beforeEach(() => useStatus.setState({ snapshot: null, joins: 0 }))

  it("counts the status channel's joins, a rejoin after the unit comes back included", () => {
    let joined
    const join = { receive: vi.fn((status, callback) => (status === 'ok' && (joined = callback), join)) }
    const channel = { on: vi.fn(), join: vi.fn(() => join), leave: vi.fn() }
    useStatus.getState().listen({ channel: () => channel })
    expect(useStatus.getState().joins).toBe(0)

    joined()
    joined()

    expect(useStatus.getState().joins).toBe(2)
  })
})
