@AGENTS.md

# Tandas — Project Context

App para administrar la "vida en grupo" de amigos que se reúnen recurrentemente: tandas de ahorro, cenas semanales, banda, etc. Reglas custom (escritas y votadas por el grupo) que la app ejecuta automáticamente: multas, anfitrión rotativo, splitwise de gastos, pots de poker, fondo común.

## Stack

- **Next.js 16** (App Router, Server Components, Server Actions, Turbopack) — read `node_modules/next/dist/docs/` for v16 breaking changes
- **React 19** + **Tailwind CSS v4** + **shadcn/ui**
- **Supabase** (Postgres + RLS + Auth + Realtime + Edge Functions)
- **TanStack Query v5** solo para vistas reactivas
- **Zod** + **React Hook Form** en boundary
- **PWA** mobile-first (web-push con VAPID)

## Estructura

```
app/                       # rutas Next, dumb (solo composición)
components/ui/             # shadcn primitives
components/shell/          # AppShell, BottomNav, GroupHeader
features/<dominio>/        # actions, queries, schemas, components, hooks
  groups · members · events · rules · fines · pots · expenses
  votes · notifications · fund · profile
lib/
  supabase/ db/ push/ cron/ i18n/ schemas/ utils/
supabase/
  migrations/              # versionadas, aplican via Supabase CLI
  functions/dispatch-push/ # Edge Function para web-push
  tests/                   # SQL harness (RLS + rule engine + balance view)
e2e/                       # Playwright mobile (10–15 flows críticos)
docs/superpowers/
  specs/                   # design docs (este es el primero)
  plans/                   # implementation plans (writing-plans output)
```

## Reglas de import (forzadas por ESLint `eslint-plugin-boundaries`)

- `features/A` ❌ no importa de `features/B`. Compartido → `lib/` o feature dedicada.
- `lib/` ❌ no importa de `features/` ni `app/`.
- `app/` ❌ sin lógica de negocio.
- Server actions ❌ no llaman otros server actions.
- Toda mutación: **Zod → server action → RPC `security definer` → revalidate path**.

## Naming

- Components: `PascalCase.tsx`, default export
- Hooks: `useXxx.ts`, named export
- Server actions: `actions.ts`, named camelCase
- Queries: `queries.ts`, prefijo `get` / `list`
- Schemas: `XxxSchema` + type `Xxx = z.infer<typeof XxxSchema>`
- RPCs SQL: `snake_case`

## Spec

`docs/superpowers/specs/2026-04-29-tandas-design.md` — diseño completo aprobado.

## DoD por PR

- `npm run build` ✓
- `tsc --noEmit` ✓
- `npm run test` ✓ (unit + int + sql)
- ESLint ✓
- Si toca SQL → `npm run test:sql` ✓
- Si toca UI → al menos 1 e2e relevante green

## Branch heredada

`claude/friend-group-manager-7dQVV` (en `josejmizrahi/tandas`) tiene un primer bootstrap en Vite + 14 tablas SQL. **NO usar como base de Vite** (descartado), pero **sí cherry-pick las 3 migrations** (`supabase/migrations/0000{1,2,3}_*.sql`) que son la base de `core_schema` + `rls` + `rpcs`. Los 4 fixes documentados en el spec aplican antes de mergear.
