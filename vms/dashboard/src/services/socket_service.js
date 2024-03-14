import { Socket } from 'phoenix'

export const vmsDashboardSocket = new Socket(import.meta.env.VITE_BASE_WS + "/sockets/dashboard", {})
vmsDashboardSocket.connect();