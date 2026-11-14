import { useEffect, useState } from 'react'

/**
 * The board `fetchBoard` answers, for the `OvcsTopBar`: read while `connected`, then again `intervalMs` after each
 * read ended, so never two at once, with the `offsetMs` of its clock from this browser's at the read, so its clock
 * keeps time between reads; `null` until first read, and again once disconnected, as its clock and load are then
 * unknown. A failed read keeps what it had.
 */
export function useOvcsBoard(fetchBoard, connected, intervalMs = 10_000) {
  const [board, setBoard] = useState(null)

  useEffect(() => {
    if (!connected) {
      setBoard(null)
      return undefined
    }
    let live = true
    let timer = null
    const read = async () => {
      try {
        const next = await fetchBoard()
        if (live) setBoard({ ...next, offsetMs: Date.parse(next.time) - Date.now() })
      } catch {
        // The board shown stays; the next read may answer.
      }
      if (live) timer = setTimeout(read, intervalMs)
    }
    read()
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [fetchBoard, connected, intervalMs])

  return board
}

/** Each of the board's interfaces with its addresses, as `[name, addresses]` pairs. */
export function boardInterfaces(board) {
  return (board?.interfaces ?? []).map(({ name, addresses }) => [name, addresses.join(', ')])
}

/**
 * The board's load as the top bar shows it: its CPU's busy share, rounded, with its `tone`, a warning from 90 %, its
 * 1, 5 and 15 minute load averages as `uptime` prints them, and the share of its memory in use, rounded, with its
 * `memoryTone`, a warning from 90 %; each `null` where the board does not report it.
 */
export function boardLoad(board) {
  if (!board) return null
  const { cpuPercent, loadAverage, memoryPercent } = board

  return {
    cpu: cpuPercent == null ? null : `${Math.round(cpuPercent)} %`,
    tone: cpuPercent == null ? null : cpuPercent >= 90 ? 'warn' : 'ok',
    load: loadAverage ? loadAverage.map((average) => average.toFixed(2)).join(', ') : null,
    memory: memoryPercent == null ? null : `${Math.round(memoryPercent)} %`,
    memoryTone: memoryPercent == null ? null : memoryPercent >= 90 ? 'warn' : 'ok'
  }
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
