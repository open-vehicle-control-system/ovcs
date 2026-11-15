import { describe, it, expect } from 'vitest'
import {
  disksText,
  droppedByTopic,
  droppedShortText,
  droppedText,
  formatBytes,
  formatDuration,
  formatRate,
  formatShortTime
} from '../format.js'

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

  it('counts the drops in short, for a column named dropped', () => {
    expect(droppedShortText([{ topic: '/tf', count: 4 }, { topic: '/objects', count: 96 }], 5400)).toBe('100 · 1.8 %')
    expect(droppedShortText([{ topic: '/tf', count: 4 }], null)).toBe('4')
    expect(droppedShortText([], 5400)).toBe('none')
  })

  it('writes a rate in bytes a second', () => {
    expect([null, 19_333_333, 640].map(formatRate)).toEqual(['–', '19.3 MB/s', '640 B/s'])
  })

  it('writes a time as a short date and the hour, in the reader\'s locale', () => {
    expect(formatShortTime(null)).toBe('–')
    expect(formatShortTime('2026-11-15T09:12:31.000000Z')).toBe(
      new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(
        new Date('2026-11-15T09:12:31Z')
      )
    )
  })

  it('names the disks of the parts, with their count when there are several', () => {
    const disks = [
      { id: 'stick', label: 'ovcs-recordings' },
      { id: 'internal', internal: true }
    ]
    expect(disksText([{ number: 1, disk: 'stick' }], disks)).toBe('ovcs-recordings')
    expect(disksText([{ number: 1, disk: 'stick' }, { number: 2, disk: 'internal' }], disks)).toBe("2 parts · ovcs-recordings, Unit's storage")
    expect(disksText([{ number: 1, disk: 'gone' }, { number: 2, disk: 'gone' }], disks)).toBe('2 parts · gone')
    expect(disksText([], disks)).toBe('–')
  })
})
