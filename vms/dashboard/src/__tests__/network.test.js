import { describe, it, expect } from 'vitest'
import { nextLoads } from '../network.js'

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

  it('skips an interface without a bit timing', () => {
    expect(nextLoads([eth0, can0(1000)], { 2: 1 })).toEqual({ loads: {}, bytes: { 3: 1000 } })
  })
})
