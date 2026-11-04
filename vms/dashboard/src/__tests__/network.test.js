import { describe, it, expect } from 'vitest'
import { formatBitrate, formatBytes, formatCount, isErrorCounter, nextLoads } from '../network.js'

const can0 = (bytes) => ({
  attributes: {
    interfaceName: 'can0',
    statistics: { ifindex: 3, linkinfo: { info_data: { bittiming: { bitrate: 500000 } } }, stats64: { rx: { bytes } } }
  }
})
const eth0 = { attributes: { interfaceName: 'eth0', statistics: { ifindex: 2, stats64: { rx: { bytes: 99 } } } } }

describe('network', () => {
  it('has no load on the first sample of an interface', () => {
    expect(nextLoads([can0(1000)], {})).toEqual({ loads: {}, bytes: { 3: 1000 } })
  })

  it('computes the load from the bytes received since the previous sample', () => {
    expect(nextLoads([can0(7250)], { 3: 1000 })).toEqual({ loads: { 3: 10 }, bytes: { 3: 7250 } })
  })

  it('groups the digits of a count', () => {
    expect(formatCount(53662790)).toBe('53,662,790')
    expect(formatCount(0)).toBe('0')
  })

  it('shows bytes in decimal units with one decimal', () => {
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(1000)).toBe('1 kB')
    expect(formatBytes(49909584)).toBe('49.9 MB')
    expect(formatBytes(307572954)).toBe('307.6 MB')
    expect(formatBytes(2500000000)).toBe('2.5 GB')
  })

  it('shows a bitrate in kbit/s or Mbit/s', () => {
    expect(formatBitrate(500000)).toBe('500 kbit/s')
    expect(formatBitrate(1000000)).toBe('1 Mbit/s')
    expect(formatBitrate(null)).toBe('—')
  })

  it('tells the counters that count a fault', () => {
    expect(['errors', 'dropped', 'crc_errors', 'collisions', 'over_errors'].every(isErrorCounter)).toBe(true)
    expect(['bytes', 'packets', 'multicast', 'carrier_changes'].some(isErrorCounter)).toBe(false)
  })

  it('skips an interface without a bit timing', () => {
    expect(nextLoads([eth0, can0(1000)], { 2: 1 })).toEqual({ loads: {}, bytes: { 3: 1000 } })
  })
})
