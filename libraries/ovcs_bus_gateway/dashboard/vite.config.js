import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The gateway the dev server proxies to, e.g. a vehicle's bridge board.
const gateway = process.env.OVCS_BUS_GATEWAY ?? 'http://localhost:4100'

export default defineConfig({
  plugins: [react()],
  resolve: {
    // @ovcs/ui is linked by path and has its own React for its tests: use this app's.
    dedupe: ['react', 'react-dom']
  },
  build: {
    outDir: '../priv/static',
    emptyOutDir: true
  },
  server: {
    proxy: {
      '/api': gateway,
      '/socket': { target: gateway, ws: true }
    }
  }
})
