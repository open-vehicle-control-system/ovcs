import { fileURLToPath, URL } from 'node:url'

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  build: {
    outDir: '../priv/static',
    emptyOutDir: true
  },
  server: {
    proxy: {
      '/api': 'http://localhost:4100',
      '/ws': { target: 'http://localhost:4100', ws: true }
    }
  }
})
