const COUNT = new Intl.NumberFormat('en-US')

/** A counter with its digits grouped. */
export const formatCount = (count) => COUNT.format(count)

const scaled = (value, units) => {
  for (const [size, unit] of units) {
    if (value >= size) return `${Number((value / size).toFixed(1))} ${unit}`
  }
  return null
}

const BYTE_UNITS = [
  [1e9, 'GB'],
  [1e6, 'MB'],
  [1e3, 'kB']
]

/** Bytes in decimal units, with one decimal at most. */
export const formatBytes = (bytes) => scaled(bytes, BYTE_UNITS) ?? `${bytes} B`

/** A bitrate in kbit/s or Mbit/s. */
export function formatBitrate(bitrate) {
  if (bitrate == null) return '—'
  return (
    scaled(bitrate, [
      [1e6, 'Mbit/s'],
      [1e3, 'kbit/s']
    ]) ?? `${bitrate} bit/s`
  )
}

/** Whether a counter counts faults: its errors, the packets it dropped and its collisions. */
export const isErrorCounter = (field) => field.endsWith('errors') || field === 'dropped' || field === 'collisions'

/**
 * Each CAN interface's bus load, in percent of its bitrate, from the bytes received since the previous sample, and the
 * bytes to compare the next sample with. The samples are a second apart; an interface's first sample has no load.
 */
export function nextLoads(interfaces, previousBytes) {
  const loads = {}
  const bytes = {}
  for (const { attributes } of interfaces) {
    const { ifindex, linkinfo, stats64 } = attributes.statistics
    const bitrate = linkinfo?.info_data?.bittiming?.bitrate
    if (bitrate == null) continue
    bytes[ifindex] = stats64.rx.bytes
    if (previousBytes[ifindex] !== undefined) {
      loads[ifindex] = Math.trunc(((bytes[ifindex] - previousBytes[ifindex]) * 8 * 100) / bitrate)
    }
  }
  return { loads, bytes }
}
