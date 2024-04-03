import { Socket } from 'phoenix'

export const infotainmentSocket = new Socket(import.meta.env.VITE_BASE_WS + "/sockets/dashboard", {})
infotainmentSocket.connect();