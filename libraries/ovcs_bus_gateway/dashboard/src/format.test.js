import { describe, expect, test } from 'vitest'
import { ago, duration, formatValue, isLive } from './format'

describe('ago', () => {
  test('reads as a phrase', () => {
    expect(ago(300)).toBe('just now')
    expect(ago(2_778_000)).toBe('46 min ago')
  })
})

describe('duration', () => {
  test('reads in the largest whole unit', () => {
    expect(duration(400)).toBe('now')
    expect(duration(4_200)).toBe('4 s')
    expect(duration(59_000)).toBe('59 s')
    expect(duration(2_778_000)).toBe('46 min')
    expect(duration(3 * 3_600_000)).toBe('3 h')
    expect(duration(50 * 3_600_000)).toBe('2 d')
  })

  test('treats a negative span, from clock skew, as now', () => {
    expect(duration(-5_000)).toBe('now')
  })
})

describe('formatValue', () => {
  test('gives each kind of value its text and tone', () => {
    expect(formatValue(true)).toEqual({ text: 'true', tone: 'ok' })
    expect(formatValue(false)).toEqual({ text: 'false', tone: 'muted' })
    expect(formatValue(null)).toEqual({ text: '—', tone: 'muted' })
    expect(formatValue(12.5)).toEqual({ text: '12.5', tone: 'plain' })
    expect(formatValue('parking')).toEqual({ text: 'parking', tone: 'plain' })
  })
})

describe('isLive', () => {
  test('is true only for a signal whose value changed within the window', () => {
    expect(isLive({ changeSeenAt: 10_000 }, 11_500)).toBe(true)
    expect(isLive({ changeSeenAt: 10_000 }, 13_000)).toBe(false)
    expect(isLive({ changeSeenAt: null }, 10_000)).toBe(false)
  })
})
