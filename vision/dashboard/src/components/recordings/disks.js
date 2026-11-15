/** The free bytes a disk keeps: the bag exporter's default `free_floor_bytes:`, below which a recording leaves it. */
export const FREE_FLOOR_BYTES = 1_000_000_000

/** The disk a recording started now goes on, as the unit chooses it: the first in the order mounted, turned on and with the free floor; `null` for none. */
export const nextDisk = (disks) =>
  disks.find(
    (disk) => disk.position != null && disk.enabled && disk.state === 'mounted' && Number.isInteger(disk.freeBytes) && disk.freeBytes >= FREE_FLOOR_BYTES
  ) ?? null

/** The bytes a recording writes a second over its duration so far; `null` before it has written or lasted anything. */
export const writeRate = ({ bytes, durationMs }) => (bytes > 0 && durationMs > 0 ? bytes / (durationMs / 1000) : null)

/** The milliseconds before a disk with `freeBytes` free falls to the free floor at `rate` bytes a second; `null` when either is unknown. */
export const timeLeftMs = (freeBytes, rate) =>
  freeBytes == null || rate == null ? null : (Math.max(freeBytes - FREE_FLOOR_BYTES, 0) / rate) * 1000
