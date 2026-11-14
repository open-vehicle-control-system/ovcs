import { Socket } from 'phoenix'

// Phoenix closes a socket whose heartbeat got no answer by the next one: a link gone without closing is noticed within two of them.
export const HEARTBEAT_MS = 5000

export const dashboardSocket = new Socket(import.meta.env.VITE_BASE_WS + "/sockets/dashboard", { heartbeatIntervalMs: HEARTBEAT_MS })
dashboardSocket.connect()
