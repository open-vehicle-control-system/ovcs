import { describe, it, expect } from 'vitest'
import { droppedText, formatBytes, formatDuration } from '../format.js'

describe('recording figures', () => {
  it('writes bytes in decimal units', () => {
    expect([null, 812, 3_400_000, 12_100_000_000].map(formatBytes)).toEqual(['–', '812 B', '3.4 MB', '12.1 GB'])
  })

  it('writes a duration in its largest units', () => {
    expect([null, 42_900, 185_000, 3_720_000].map(formatDuration)).toEqual(['–', '42 s', '3 min 05 s', '1 h 02 min'])
  })

  it('counts the drops, then each topic', () => {
    expect(droppedText([])).toBe('none')
    expect(droppedText([{ topic: '/tf', count: 4 }, { topic: '/stereo/depth/image_rect', count: 2 }])).toBe(
      '6: /tf 4, /stereo/depth/image_rect 2'
    )
  })
})
