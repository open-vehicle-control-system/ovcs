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
