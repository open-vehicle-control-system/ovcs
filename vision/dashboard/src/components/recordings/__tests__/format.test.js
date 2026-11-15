import { describe, it, expect } from 'vitest'
import { droppedByTopic, droppedText, formatBytes, formatDuration } from '../format.js'

describe('recording figures', () => {
  it('writes bytes in decimal units', () => {
    expect([null, 812, 3_400_000, 12_100_000_000].map(formatBytes)).toEqual(['–', '812 B', '3.4 MB', '12.1 GB'])
  })

  it('writes a duration in its largest units', () => {
    expect([null, 42_900, 185_000, 3_720_000].map(formatDuration)).toEqual(['–', '42 s', '3 min 05 s', '1 h 02 min'])
  })

  it('counts the drops and their share of the messages that reached the recorder', () => {
    const dropped = [{ topic: '/tf', count: 4 }, { topic: '/stereo/depth/image_rect', count: 96 }]
    expect(droppedText([], 5400)).toBe('none')
    expect(droppedText(dropped, 5400)).toBe('100 messages · 1.8 %')
    expect(droppedText([{ topic: '/tf', count: 1 }], 99_999)).toBe('1 message · < 0.1 %')
    expect(droppedText(dropped, null)).toBe('100 messages')
  })

  it('lists the topics that dropped the most first', () => {
    const dropped = [{ topic: '/tf', count: 4 }, { topic: '/objects', count: 138 }, { topic: '/center/camera_info', count: 4 }]
    expect(droppedByTopic(dropped)).toEqual([
      { topic: '/objects', count: 138 },
      { topic: '/center/camera_info', count: 4 },
      { topic: '/tf', count: 4 }
    ])
  })
})
