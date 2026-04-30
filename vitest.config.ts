import { defineConfig } from 'vitest/config'
import path from 'node:path'

export default defineConfig({
  test: {
    environment: 'jsdom',
    setupFiles: ['./tests/setup.ts'],
    include: ['lib/**/*.test.ts', 'features/**/*.test.{ts,tsx}'],
    exclude: ['features/**/*.int.test.ts', 'node_modules/**', '.next/**'],
  },
  resolve: {
    alias: { '@': path.resolve(process.cwd()) },
  },
})
