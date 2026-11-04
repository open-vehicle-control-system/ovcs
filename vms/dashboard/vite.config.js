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
  // 5174 is the vision dashboard's.
  server: {
    port: 5173,
    strictPort: true
  },
  build: {
    outDir: "../api/priv/static/"
  }
})
