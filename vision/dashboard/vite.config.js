import { fileURLToPath, URL } from 'node:url'

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  resolve: {
    dedupe: ['react', 'react-dom'],
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
