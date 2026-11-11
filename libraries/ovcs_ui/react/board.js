import { useEffect, useState } from 'react'

/**
 * The board `fetchBoard` answers, for the `OvcsTopBar`: read while `connected`, then every `intervalMs`, with the
 * `offsetMs` of its clock from this browser's at the read, so its clock keeps time between reads; `null` until first
 * read. A failed read keeps what it had.
 */
export function useOvcsBoard(fetchBoard, connected, intervalMs = 10_000) {
  const [board, setBoard] = useState(null)

  useEffect(() => {
    if (!connected) return undefined
    let live = true
    const read = () =>
      fetchBoard().then(
        (next) => {
          if (live) setBoard({ ...next, offsetMs: Date.parse(next.time) - Date.now() })
        },
        () => {}
      )
    read()
    const timer = setInterval(read, intervalMs)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [fetchBoard, connected, intervalMs])

  return board
}

/** Each of the board's interfaces with its addresses, as `[name, addresses]` pairs. */
export function boardInterfaces(board) {
  return (board?.interfaces ?? []).map(({ name, addresses }) => [name, addresses.join(', ')])
}

/**
 * The board's clock at `nowMs`, in UTC: `time`, dated when it is not synchronized, as a board whose clock never set
 * reads 1970, and its synchronization, `state` with its `tone`, both `null` on a host, which reports none.
 */
export function boardClock(board, nowMs) {
  if (!board) return null
  const iso = new Date(nowMs + board.offsetMs).toISOString()
  const synchronized = board.clockSynchronized

  return {
    time: synchronized === false ? `${iso.slice(0, 10)} ${iso.slice(11, 19)} UTC` : `${iso.slice(11, 19)} UTC`,
    tone: synchronized == null ? null : synchronized ? 'ok' : 'warn',
    state: synchronized == null ? null : synchronized ? 'synchronized' : 'not synchronized'
  }
}
