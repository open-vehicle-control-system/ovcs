import { fileURLToPath, URL } from 'node:url'

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// The gateway the dev server proxies to, e.g. a vehicle's bridge board.
const gateway = process.env.OVCS_BUS_GATEWAY ?? 'http://localhost:4100'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    },
    // @ovcs/ui is linked by path and has its own Vue for its tests: use this app's.
    dedupe: ['vue']
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
