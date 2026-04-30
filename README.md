# Tandas

Mini-app para administrar la "vida en grupo" de amigos: tandas de ahorro, cenas semanales, pots de poker, gastos compartidos. Reglas custom (escritas y votadas por el grupo) que la app ejecuta automáticamente.

> Mobile-first PWA. Next.js 16 + Supabase + shadcn/ui + Tailwind CSS v4.

## Spec

`docs/superpowers/specs/2026-04-29-tandas-design.md` — diseño completo.
`docs/superpowers/plans/2026-04-29-tandas-phase-1-foundation.md` — plan ejecutado.

## Setup local

```bash
npm install
cp .env.example .env.local      # llena las 2 NEXT_PUBLIC_* con tus credenciales de Supabase
npm run dev
```

Por defecto el proyecto está cableado al Supabase en la nube `fpfvlrwcskhgsjuhrjpz`. Si quieres correr local con Docker:

```bash
npm run db:start         # supabase local (requiere Docker)
npm run db:reset         # aplica las 4 migrations desde cero
npm run db:types         # regenera lib/db/types.ts
```

## Scripts

| Script | Hace |
|---|---|
| `npm run dev` | Next dev server |
| `npm run build` | Build prod |
| `npm run lint` | ESLint (incluye boundaries entre features) |
| `npm run typecheck` | tsc --noEmit |
| `npm test` | Vitest unit |
| `npm run test:int` | Vitest integration (necesita Supabase) |
| `npm run test:e2e` | Playwright mobile (iPhone 13 + Pixel 7) |
| `npm run db:start` | Levanta Supabase local |
| `npm run db:reset` | Aplica todas las migrations desde cero |
| `npm run db:types` | Regenera `lib/db/types.ts` desde Supabase local |

## Estructura

```
app/                       # rutas Next, dumb (solo composición)
components/ui/             # shadcn primitives (button, sheet, form, ...)
components/shell/          # AppShell, GroupHeader, ProfileSheet
features/<dominio>/        # actions, queries, schemas, components, hooks
  groups · members · profile · (más en Phase 2-7)
lib/
  supabase/{server,browser,middleware}.ts
  db/types.ts              # generado desde Supabase
  schemas/{ids,money,enums}.ts
  utils.ts                 # cn helper de shadcn
supabase/migrations/       # 4 migrations versionadas
e2e/                       # Playwright mobile (10–15 flows críticos al final)
docs/superpowers/{specs,plans}/
```

## Reglas de import (forzadas por ESLint)

- `features/A` ❌ no importa de `features/B` (sube a `lib/` o crea feature compartida)
- `lib/` ❌ no importa de `features/` ni `app/`
- `app/` ❌ sin lógica de negocio (solo composición)
- Toda mutación: **Zod → server action → RPC `security definer` → revalidate path**

## Implementación por fases

| Fase | Estado | Deliverable |
|---|---|---|
| **1** | ✅ shipped | Auth (phone OTP + email magic link) + create/join group + group home con miembros |
| 2 | pending | Eventos + RSVP + check-in |
| 3 | pending | Reglas + votos |
| 4 | pending | Multas (auto + manual + apelación) |
| 5 | pending | Pots + IOUs |
| 6 | pending | Expenses + Splitwise + balance hero |
| 7 | pending | Notifications + web push + pg_cron |
| 8 | pending | PWA polish + tests sweep |
| 9 | pending | Production hardening |

## Deploy

Push a `main` → Vercel auto-deploya. Variables de entorno en Vercel Settings (mismas 2 que `.env.example`).

## Stack

- **Next.js 16** (App Router, Server Components, Server Actions, Turbopack)
- **React 19** + **Tailwind CSS v4** + **shadcn/ui**
- **Supabase** (Postgres + RLS + Auth + Realtime + Edge Functions)
- **TanStack Query v5** (vistas reactivas — Phase 3+)
- **Zod** + **React Hook Form** en boundary
- **PWA** mobile-first con web-push (VAPID, Phase 7)

## Co-Authored-By

`claude-flow <ruv@ruv.net>` — todo el código de Phase 1 fue generado con Claude Code.
