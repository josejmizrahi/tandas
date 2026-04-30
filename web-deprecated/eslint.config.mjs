import { defineConfig, globalIgnores } from 'eslint/config'
import nextVitals from 'eslint-config-next/core-web-vitals'
import nextTs from 'eslint-config-next/typescript'
import boundaries from 'eslint-plugin-boundaries'

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  {
    plugins: { boundaries },
    settings: {
      'boundaries/elements': [
        { type: 'app',     pattern: 'app/**' },
        { type: 'feature', pattern: 'features/*/**', capture: ['name'] },
        { type: 'lib',     pattern: 'lib/**' },
        { type: 'ui',      pattern: 'components/ui/**' },
        { type: 'shell',   pattern: 'components/shell/**' },
        { type: 'tests',   pattern: '{tests,e2e}/**' },
      ],
      'boundaries/include': ['**/*.{ts,tsx}'],
    },
    rules: {
      'boundaries/element-types': ['error', {
        default: 'allow',
        rules: [
          { from: 'lib',     disallow: ['app', 'feature', 'shell'] },
          { from: 'ui',      disallow: ['app', 'feature', 'shell'] },
          { from: 'app',     allow:    ['feature', 'lib', 'ui', 'shell'] },
          { from: 'feature', disallow: ['app'] },
          { from: 'shell',   disallow: ['app'] },
          // A file in features/X may only import from features/X — never features/Y.
          {
            from: [['feature', { name: '${from.name}' }]],
            disallow: [['feature', { name: '!${from.name}' }]],
            message: "Feature '${dependency.name}' cannot be imported from feature '${file.name}'. Move shared code to lib/.",
          },
        ],
      }],
    },
  },
  globalIgnores([
    '.next/**',
    'node_modules/**',
    'lib/db/types.ts',
    'public/**',
    'out/**',
    'build/**',
    'next-env.d.ts',
  ]),
])

export default eslintConfig
