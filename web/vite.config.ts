import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Relative base so the built site can be hosted from any path
// (root, subdirectory, or a personal domain).
export default defineConfig({
  base: './',
  plugins: [react()],
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
  },
})
