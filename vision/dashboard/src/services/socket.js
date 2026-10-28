import { Socket } from 'phoenix'

export const dashboardSocket = new Socket(import.meta.env.VITE_BASE_WS + "/sockets/dashboard", {})
dashboardSocket.connect()
