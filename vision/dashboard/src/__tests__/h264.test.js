import { describe, expect, it } from 'vitest'
import { codecOf, nalUnits, readVideoFrame } from '../h264.js'

const SPS = [0x67, 0x64, 0x00, 0x28, 0xac, 0xd9]
const PPS = [0x68, 0xeb, 0xe3, 0xcb]
const IDR = [0x65, 0x88, 0x84, 0x00]
const SLICE = [0x41, 0x9a, 0x02]
const START = [0, 0, 0, 1]

const annexB = (...units) => new Uint8Array(units.flatMap((unit, index) => [...(index % 2 ? [0, 0, 1] : START), ...unit]))

describe('nalUnits', () => {
  it('splits an Annex B frame at its 3- and 4-byte start codes', () => {
    expect(nalUnits(annexB(SPS, PPS, IDR)).map((unit) => [...unit])).toEqual([SPS, PPS, IDR])
  })
})

describe('codecOf', () => {
  it("names the profile, constraints and level of a key frame's sequence parameter set", () => {
    expect(codecOf(annexB(SPS, PPS, IDR))).toBe('avc1.640028')
  })

  it('is none for a frame without a sequence parameter set', () => {
    expect(codecOf(annexB(SLICE))).toBeNull()
  })
})

describe('readVideoFrame', () => {
  it('reads the flags, capture time, size and stream bytes the video channel pushes', () => {
    const payload = new Uint8Array(13 + 3)
    const view = new DataView(payload.buffer)
    view.setUint8(0, 1)
    view.setBigInt64(1, -123456789n, true)
    view.setUint16(9, 2028, true)
    view.setUint16(11, 1520, true)
    payload.set([7, 8, 9], 13)

    const frame = readVideoFrame(payload.buffer)

    expect(frame).toMatchObject({ key: true, captureUs: -123456789, width: 2028, height: 1520 })
    expect([...frame.data]).toEqual([7, 8, 9])
  })
})
