import { defineConfig } from 'vitest/config'
import path from 'node:path'

export default defineConfig({
  test: {
    environment: 'node',
    setupFiles: ['./tests/setup.ts'],
    include: ['features/**/*.int.test.ts', 'tests/integration/**/*.test.ts'],
    pool: 'forks',
    poolOptions: { forks: { singleFork: true } },
    testTimeout: 20_000,
  },
  resolve: {
    alias: { '@': path.resolve(process.cwd()) },
  },
})
