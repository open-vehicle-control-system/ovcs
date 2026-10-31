import react from '@vitejs/plugin-react'
import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vitest/config'

// One jsdom environment and both framework plugins: each only transforms its own file types.
export default defineConfig({
  plugins: [vue(), react()],
  test: { environment: 'jsdom', setupFiles: ['./react/test-setup.js'] }
})
