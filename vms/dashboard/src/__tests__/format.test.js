import { describe, it, expect } from 'vitest'
import { displayValue, isMultiline, isNumeric, liveValue, unitOf } from '../format.js'

// Booleans never reach displayValue: MetricValue renders them.
describe('format', () => {
  it('shows a missing value as its placeholder, a dash by default', () => {
    expect(displayValue(null, {}, undefined)).toBe('—')
    expect(displayValue(undefined, { placeholder: 'n/a' })).toBe('n/a')
  })

  it('rounds numbers to two places, followed by the unit', () => {
    expect(displayValue(12.346, {}, 'km/h')).toBe('12.35 km/h')
    expect(displayValue(7, {}, null)).toBe('7')
  })

  it('reads decimals sent as strings as numbers', () => {
    expect(displayValue('3.14159', {}, null)).toBe('3.14')
    expect(isNumeric('3.14159')).toBe(true)
    expect(isNumeric('  ')).toBe(false)
  })

  it('shows a fraction as a percentage with one decimal', () => {
    expect(displayValue(0.4567, {}, 'fraction')).toBe('45.7 %')
  })

  it("prefers the row's unit over the publisher's", () => {
    expect(unitOf({ unit: 'fraction' }, 'V')).toBe('fraction')
    expect(displayValue(0.5, { unit: 'fraction' }, 'V')).toBe('50 %')
  })

  it('joins lists with commas', () => {
    expect(displayValue(['P0300', 'P0171'], {})).toBe('P0300, P0171')
  })

  it('shows a map as JSON', () => {
    expect(displayValue({ mode: 'P', gear: 1 }, {})).toBe('{\n  "mode": "P",\n  "gear": 1\n}')
  })

  it('shows other values as they are, without a unit', () => {
    expect(displayValue('  ', {})).toBe('  ')
    expect(displayValue('ready', {}, 'V')).toBe('ready')
  })

  it('tells a multi-line string apart', () => {
    expect(isMultiline('a\nb')).toBe(true)
    expect(isMultiline('ab')).toBe(false)
    expect(isMultiline(12)).toBe(false)
  })

  it("shows a status metric's live value with four decimals at most", () => {
    expect(liveValue(0.123456)).toBe('0.1235')
    expect(liveValue('on')).toBe('on')
    expect(liveValue(null)).toBe('')
    expect(liveValue(undefined)).toBe('')
  })
})
