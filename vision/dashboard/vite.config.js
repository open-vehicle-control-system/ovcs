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
  // 5173 is the VMS dashboard's.
  server: {
    port: 5174,
    strictPort: true
  },
  build: {
    outDir: "../api/priv/static/"
  }
})
