import { describe, it, expect } from 'vitest'
import { FREE_FLOOR_BYTES, nextDisk, timeLeftMs, writeRate } from '../disks.js'

const disk = (id, attributes) => ({ id, position: 0, enabled: true, state: 'mounted', freeBytes: 10e9, ...attributes })

describe('the disk a recording takes', () => {
  it('is the first in the order that is mounted, turned on and has the free floor', () => {
    const cases = [
      [[disk('a'), disk('b')], 'a'],
      [[disk('a', { enabled: false }), disk('b')], 'b'],
      [[disk('a', { state: 'ejected' }), disk('b')], 'b'],
      [[disk('a', { freeBytes: FREE_FLOOR_BYTES - 1 }), disk('b')], 'b'],
      [[disk('a', { freeBytes: FREE_FLOOR_BYTES }), disk('b')], 'a'],
      [[disk('a', { freeBytes: null }), disk('b')], 'b'],
      [[disk('a', { position: null }), disk('b')], 'b'],
      [[disk('a', { enabled: false })], null],
      [[], null]
    ]
    for (const [disks, id] of cases) expect(nextDisk(disks)?.id ?? null).toBe(id)
  })
})

describe('a recording in progress', () => {
  it('writes its bytes over its duration, unknown before it has either', () => {
    expect(writeRate({ bytes: 812_000_000, durationMs: 42_000 })).toBeCloseTo(19_333_333, 0)
    expect(writeRate({ bytes: 0, durationMs: 0 })).toBeNull()
    expect(writeRate({ bytes: 812, durationMs: null })).toBeNull()
    expect(writeRate({ bytes: null, durationMs: 42_000 })).toBeNull()
  })

  it('has the time its disk takes to fall to the free floor at that rate', () => {
    expect(timeLeftMs(FREE_FLOOR_BYTES + 3_600_000_000, 1_000_000)).toBe(3_600_000)
    expect(timeLeftMs(FREE_FLOOR_BYTES / 2, 1_000_000)).toBe(0)
    expect(timeLeftMs(null, 1_000_000)).toBeNull()
    expect(timeLeftMs(10e9, null)).toBeNull()
  })
})
