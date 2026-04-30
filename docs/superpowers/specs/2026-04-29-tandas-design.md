# Tandas — Design Spec

**Date:** 2026-04-29
**Status:** Approved (design phase). Implementation plan to follow via writing-plans.
**Repo:** `josejmizrahi/tandas`
**Stack target:** Next.js 16 App Router + Supabase + shadcn/ui + Tailwind v4, mobile-first PWA.

---

## 1. Overview

Tandas es una mini-app para administrar la "vida en grupo" de cualquier conjunto de amigos que se reúna recurrentemente (tanda de ahorro, cena semanal, banda, grupo de domingo). La premisa: **todo se rige por reglas que el grupo mismo escribe, vota y modifica, y la app las ejecuta automáticamente**.

### Loop principal

1. Alguien crea el grupo, define vocabulario ("Tanda", "Cena", "Reunión"), día/hora default, moneda, threshold de votación, y si quiere fondo común.
2. Comparte código de invitación. Cada miembro queda con un orden de turno.
3. La app crea eventos automáticamente: asigna anfitrión por rotación, crea registros de asistencia, calcula deadline de RSVP.
4. Miembros confirman, llegan, hacen check-in. Si no llegan / cancelan / no-show, la app lo registra.
5. Al cerrar el evento, el rule engine aplica multas según las reglas activas (con excepciones por miembro respetadas).
6. Las multas se pagan; si el grupo tiene fondo, el dinero entra al fondo común.
7. Cualquier multa puede apelarse → abre votación → si pasa, se anula sola.
8. Reglas se proponen, votan y modifican vía consenso (cualquier miembro puede proponer).
9. Pots (juegos durante el evento) generan IOUs automáticos al ganador.
10. Gastos compartidos estilo Splitwise, con balance neto unificado (gastos − shares + payments − fines − pot owed + pot won).

### Outcomes

Tandas convierte un reglamento de WhatsApp en un sistema vivo: las reglas se ejecutan solas, el dinero del grupo se calcula solo, los conflictos se resuelven con votaciones en vez de chats interminables, y nadie tiene que ser el "policía" del grupo.

---

## 2. Decisions Log

| # | Pregunta | Decisión | Razón |
|---|---|---|---|
| 1 | Stack base | Next.js 16 App Router + Server Components + Server Actions | Patrón QI ya validado, escalable, mismo conocimiento institucional. Vite SPA descartado. |
| 2 | Layout | Mobile-first agresivo con bottom nav (5 tabs) | Loop principal (RSVP → check-in → pagar) es 100% móvil. Admin minoría. PWA obligatoria. |
| 3 | Auth v1 | Phone OTP (SMS) + Email magic link fallback | `profiles.phone` ya en schema. SMS auto-fill iOS. Email backup para recuperación. |
| 4 | WhatsApp | `wa.me` deep links para compartir invite (gratis). OTP/templates v2. | Plantillas Meta requieren approval. No bloquear ship. |
| 5 | Recordatorios | pg_cron + Web Push (VAPID) | Gratis, sin Twilio. Funciona iOS 16.4+ y Android. WhatsApp templates en v2. |
| 6 | Realtime | Supabase Realtime solo en `votes` y `events` activos | Resto refresca con TanStack Query + invalidación. Costo bajo. |
| 7 | Recurrencia | Auto-rolla siguiente evento al cerrar (idempotente vía `parent_event_id`) | Evita olvido del admin. |
| 8 | Multi-grupo | Switcher tipo Slack arriba; rutas `/g/[gid]/*` | Una sola PWA, todos los grupos adentro. |
| 9 | i18n | es-MX único en v1, strings centralizados para futuro | YAGNI hasta primera demanda real. |
| 10 | Fotos | No en v1 (recibos/comprobantes en v2) | YAGNI. |
| 11 | Tests | SQL + RLS + integration de actions + 10–15 e2e mobile | Foco: caminos del dinero. |
| 12 | Arquitectura código | Feature-sliced (`features/<dominio>/`) | Reutilización real, escalable, alineado con shadcn best practices. |

---

## 3. Architecture

### Stack

| Capa | Tecnología |
|---|---|
| Framework | Next.js 16 (App Router, RSC, Server Actions, Turbopack) |
| Runtime | Node 20 (Vercel) + Edge Functions (Supabase) para cron |
| UI | React 19 + Tailwind CSS v4 + shadcn/ui (CLI moderno) |
| State servidor | TanStack Query v5 (solo vistas reactivas: votos, balances, notifs) |
| Auth + DB | Supabase (Phone OTP + Email Magic Link) |
| Realtime | Supabase Realtime — `votes` y `events` activos |
| Cron | `pg_cron` cada 5 min → Edge Function → web-push |
| Push | `web-push` (VAPID), suscripciones en `push_subscriptions` |
| Validación | Zod en boundary (form → action) |
| Forms | React Hook Form + Zod resolver |
| Testing | Vitest (unit + integration) + Playwright (e2e mobile) + pgTAP-style SQL tests |
| Hosting | Vercel (web) + Supabase (db, auth, edge, realtime) |

### Boundaries

```
app/                     ← rutas dumb, solo composición
  └── importa de
features/<dominio>/      ← components, actions, queries, schemas, hooks
  └── importa de
lib/  components/ui/  components/shell/   ← transversal
```

### Reglas duras (forzadas por ESLint `eslint-plugin-boundaries`)

- `features/A` ❌ no importa de `features/B`. Compartido → sube a `lib/` o feature dedicada.
- `lib/` ❌ nunca importa de `features/` ni de `app/`.
- `app/` ❌ sin lógica de negocio. Solo composición.
- Server Actions ❌ no llaman otros server actions. Compartido → `lib/` o RPC.
- Toda mutación: **Zod schema → server action → RPC `security definer` → revalidate path**.

### Build / deploy

- Vercel preview por PR, prod merge a `main`.
- Migrations versionadas en `supabase/migrations/`, aplicadas en CI con Supabase CLI.
- Types autogenerados (`supabase gen types typescript`) commiteados en `lib/db/types.ts`.

---

## 4. Data Model

### Tablas existentes (del bootstrap previo, branch `claude/friend-group-manager-7dQVV`)

Las 14 tablas del primer commit son la base. Se mantienen tal cual con 4 fixes:

| Tabla | Cambio |
|---|---|
| `events` | `+ parent_event_id uuid references events(id)` (linaje recurrencias) |
| `events` | `+ auto_no_show_at timestamptz` (computado al crear, base del cron) |
| `groups` | `+ no_show_grace_minutes int not null default 60` |
| `expense_shares` | `+ percentage numeric(5,2)` cuando `split_type='percentage'` |

### Bug fixes (heredados del bootstrap)

```sql
-- BUG #1: timezone en late_arrival
-- evaluate_event_rules debe usar `at time zone g.timezone` explícito
v_threshold := (
  date_trunc('day', e.starts_at at time zone g.timezone)
  + (r.trigger->'params'->>'start_threshold_time')::interval
) at time zone g.timezone;

-- BUG #2: vote_ballots editable post-cierre
-- RLS update/delete necesita check de status='open'
create policy "ballots_update_self" on public.vote_ballots for update to authenticated
using (
  user_id = auth.uid()
  and exists (select 1 from public.votes v where v.id = vote_id and v.status = 'open')
)
with check (user_id = auth.uid());

-- BUG #3: set_turn_order ignora active
update public.group_members set turn_order = null
  where group_id = p_group_id and active;
```

### Tablas nuevas

```sql
-- Suscripciones push web (un user puede tener N devices)
create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth   text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

-- Log de notificaciones — idempotencia + historial
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  kind text not null check (kind in (
    'rsvp_deadline_2h','event_tomorrow','vote_opened','vote_closing_soon',
    'fine_issued','fine_appeal_decided','event_no_show'
  )),
  subject_type text,
  subject_id uuid,
  title text not null,
  body  text not null,
  url   text,
  sent_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, kind, subject_type, subject_id)
);

-- Job runs tracker (idempotencia + observabilidad cron)
create table public.job_runs (
  id uuid primary key default gen_random_uuid(),
  job_name text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  rows_processed int default 0,
  error text
);
```

### Vista nueva

```sql
create or replace view public.unread_notifications_count
with (security_invoker = true) as
select user_id, count(*)::int as count
from public.notifications
where read_at is null
group by user_id;
```

### Plan de migrations

```
supabase/migrations/
  00001_core_schema.sql              # cherry-pick del branch, sin cambios
  00002_rls.sql                      # del branch + fix vote_ballots
  00003_rpcs.sql                     # del branch + timezone fix + set_turn_order fix
  00004_recurrence_and_no_show.sql   # parent_event_id, auto_no_show_at, no_show_grace_minutes
  00005_push_and_notifications.sql   # 3 tablas + RPCs + view
  00006_cron_jobs.sql                # pg_cron schedules
```

---

## 5. Server Boundary

**Regla absoluta:** toda mutación pasa por RPC `security definer`. Server actions son envoltorios delgados (Zod + auth + revalidate). Reads usan RLS directo.

### Matriz de uso

| Caso | Cliente | Servidor | Por qué |
|---|---|---|---|
| Crear grupo (form) | `<form action={createGroup}>` | RPC `create_group_with_admin` | Progressive enhancement + redirect |
| RSVP / Check-in | `<form action={...}>` o `useTransition` | RPC `set_rsvp` / `check_in_attendee` | Mutación simple |
| Vote tally vivo | `useQuery` + `realtime.channel('votes:id=...')` | RLS read directo | UX necesita ver subir los yes/no |
| Lista de eventos | `<Suspense>` + RSC `await getEvents(gid)` | RLS read directo | Render servidor, streaming |
| Notif read | `useMutation` + server action | RPC `mark_notification_read` | Badge actualiza + revalidate |
| Cerrar evento + evaluar reglas | `<form action={closeEvent}>` | RPC `evaluate_event_rules` | Action revalida páginas afectadas |
| Push subscribe | client component + `navigator.serviceWorker` | RPC `register_push_subscription` | API browser |

### Anatomía de un feature module

```
features/fines/
├── schemas.ts       # Zod: PayFineSchema, IssueFineSchema, AppealFineSchema
├── queries.ts       # 'server-only' — getFinesForGroup(gid), getFinesForUser(uid, gid)
├── actions.ts       # 'use server' — payFine, issueFine, openFineAppeal
├── hooks.ts         # 'use client' — useFinesRealtime(gid), useUnreadFinesBadge(uid)
├── components/
│   ├── FinesList.tsx          # RSC, recibe data como prop
│   ├── FineRow.tsx            # client, botones pagar/apelar
│   ├── PayFineSheet.tsx       # client, sheet con confirm + form action
│   ├── IssueFineSheet.tsx     # client, admin only
│   └── AppealFineDialog.tsx   # client, abre vote
└── index.ts         # barrel — solo expone components y hooks públicos
```

### Server action pattern

```ts
// features/fines/actions.ts
'use server'
export async function payFine(_: unknown, formData: FormData) {
  const supabase = await createServerClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = PayFineSchema.safeParse({ id: formData.get('id') })
  if (!parsed.success) return { error: parsed.error.flatten() }

  const { error } = await supabase.rpc('pay_fine', { p_fine_id: parsed.data.id })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath(`/g/${formData.get('gid')}/plata/multas`)
  return { ok: true }
}
```

**3 reglas firmes:**
1. Siempre `getUser()` antes de write — RLS cubre, pero falla rápido y limpio si no hay sesión.
2. Toda action devuelve `{ ok: true }` o `{ error: { _form?: string[], <field>?: string[] } }`.
3. `revalidatePath` específico, nunca `revalidatePath('/')`.

---

## 6. Mobile Shell & Navigation

### Bottom nav (5 tabs)

| # | Tab | Ruta | Contenido |
|---|---|---|---|
| 1 | **Hoy** | `/g/[gid]/hoy` | Inbox: RSVPs vencen, votos abiertos, multas sin pagar, gastos pendientes |
| 2 | **Eventos** | `/g/[gid]/eventos` | Próximos + histórico, detalle con asistencia, check-in, cerrar |
| 3 | **Reglas** | `/g/[gid]/reglas` | Activas + propuestas + archivadas, FAB "Proponer regla" |
| 4 | **Plata** | `/g/[gid]/plata` | Balance hero + sub-tabs Multas/Gastos/Pots, "Saldar con X" |
| 5 | **Más** | `/g/[gid]/mas` | Miembros · Fondo · Settings · Switcher grupo · Salir |

Votos no son tab — viven en su subject (regla con voto en proceso, multa apelada). Miembros y Settings son baja frecuencia → "Más".

### Header (sticky)

```
┌────────────────────────────────────────────────────┐
│  [avatar] Tanda Martes ⌄          [🔔 3]  [👤]    │
└────────────────────────────────────────────────────┘
```

- `Tanda Martes ⌄` → `<Sheet side="left">` con switcher + crear grupo + unirme con código
- 🔔 → ruta `/g/[gid]/notificaciones` (full page con historial)
- 👤 → `<Sheet>` con perfil, settings personales, logout

### Tree de rutas

```
/login                          # Phone OTP + email tab
/onboarding                     # display_name + avatar opcional
/                               # picker o redirect según N grupos
/g/new                          # wizard (4 pasos)
/g/join                         # pegar invite_code
/g/[gid]/
   ├ hoy/
   ├ eventos/
   │  └ [eid]/                  # detalle + sheet check-in
   ├ reglas/
   │  ├ [rid]/                  # detalle + apelaciones
   │  └ proponer/               # full page wizard
   ├ plata/                     # balance hero + tabs
   │  ├ multas/[fid]/
   │  ├ gastos/[xid]/
   │  └ pots/[pid]/
   ├ mas/
   │  ├ miembros/
   │  ├ fondo/
   │  └ settings/
   └ notificaciones/
```

### Patrones de interacción

| Acción | Componente | Por qué |
|---|---|---|
| RSVP "Voy/Tal vez/No voy" | `ToggleGroup` inline en card | Visible sin tap extra |
| Check-in | Botón pinned bottom + confirm `Sheet` | Una mano, en el lugar |
| Pagar multa | `Sheet` con monto + comprobante (v2) | Espacio para detalles |
| Crear gasto | `Sheet` con form RHF + Zod | Form medio, no merece full page |
| Proponer regla | Página `/proponer` (wizard 3 pasos) | Necesita scroll y preview |
| Configurar preset | `Drawer` (vaul) scrollable | Más alto que sheet |
| Casting vote | `Sheet` con tally vivo (realtime) | Ver el voto en tiempo real |
| Group switcher | `Sheet side="left"` | Patrón nativo |
| Notificaciones | Página dedicada | Historial agrupado por día |
| Confirmaciones destructivas | `AlertDialog` | "Salir del grupo", "Borrar regla" |

### PWA

```
public/
  manifest.webmanifest        # name, icons, theme_color
  icon-192.png · icon-512.png · maskable-icon-512.png · apple-touch-icon.png
  sw.js                       # service worker (push + offline shell mínimo)
app/
  layout.tsx                  # <link rel="manifest"> + <meta theme-color>
  ServiceWorkerRegister.tsx   # client component que registra sw.js
```

Offline mínimo v1: app shell + última vista de "Hoy". No mutaciones offline.

### Tema

- Tailwind v4 con `@theme` inline en `globals.css`.
- Dark mode automático (prefers-color-scheme) + override manual en Más → Settings.
- Tokens semánticos: `--color-primary` (verde grupo), `--color-fine` (rojo), `--color-fund` (dorado), `--color-pot` (morado).
- shadcn defaults sin customizar a menos que duela.

---

## 7. Feature Contracts

| Feature | Owns | Exposes públicamente | RPCs |
|---|---|---|---|
| **groups** | Create, settings, switcher | `<GroupSwitcher>` `<GroupSettingsForm>` `<NewGroupWizard>` `getGroup()` `listMyGroups()` | `create_group_with_admin`, `update_group_settings` |
| **members** | Roster, roles, comité, orden de turnos | `<MembersList>` `<TurnOrderEditor>` `<JoinByCode>` `<InviteSheet>` | `join_group_by_code`, `set_turn_order`, `set_member_role`, `toggle_committee` |
| **events** | Lista, detalle, RSVP, check-in, cierre, recurrencia | `<EventCard>` `<EventDetail>` `<RsvpToggle>` `<CheckInButton>` `<CloseEventDialog>` `<EventSeriesBadge>` | `create_event`, `set_rsvp`, `check_in_attendee`, `evaluate_event_rules`, `roll_event_series` |
| **rules** | Catálogo, presets, propuesta, derogación, excepciones | `<RulesList>` `<RuleCard>` `<ProposeRuleWizard>` `<RuleExceptionsEditor>` `<RulePresetPicker>` | `propose_rule`, `archive_rule`, `update_rule_exceptions` |
| **fines** | Lista, emitir manual, pagar, apelar | `<FinesList>` `<FineRow>` `<PayFineSheet>` `<IssueFineSheet>` `<AppealFineDialog>` `<MyFinesBadge>` | `pay_fine`, `issue_manual_fine`, `open_fine_appeal` |
| **pots** | Crear, entrar, declarar ganador, IOUs | `<PotsList>` `<PotCard>` `<NewPotSheet>` `<JoinPotButton>` `<DeclareWinnerSheet>` `<PotIousList>` | `create_pot`, `add_pot_entry`, `close_pot`, `mark_pot_iou_paid` |
| **expenses** | Splitwise: alta, dividir, balances, settle-up | `<ExpensesList>` `<NewExpenseSheet>` `<ExpenseDetail>` `<BalanceHero>` `<SettleUpDialog>` | `create_expense_with_shares`, `record_payment`, `delete_expense` |
| **votes** | Detalle, casting, tally vivo, cierre | `<VoteCard>` `<VoteSheet>` `<VoteTallyBar>` `<VoteResultBanner>` `useVoteTally()` | `cast_ballot`, `close_vote` |
| **notifications** | Inbox, leído, push registration | `<NotificationsList>` `<NotificationBell>` `<NotificationItem>` `useUnreadCount()` | `mark_notification_read`, `register_push_subscription` |
| **fund** | Balance del fondo, meta, log | `<FundCard>` `<FundProgressBar>` `<FundLog>` | (read-only `groups.fund_balance` + view derivada) |
| **profile** | Auth, onboarding, datos personales | `<LoginForm>` `<OnboardingForm>` `<ProfileSheet>` | `update_profile` |

### Composiciones cross-feature (en `app/`)

| Pantalla | Compone |
|---|---|
| `/g/[gid]/hoy` | `<EventCard>` + `<MyFinesBadge>` + `<OpenVotesList>` + `<PendingExpensesAlert>` + `<RsvpReminders>` |
| `/g/[gid]/eventos/[eid]` | `<EventDetail>` + `<AttendeeChecklist>` + `<EventPotsSection>` + `<EventExpensesSection>` |
| `/g/[gid]/reglas/[rid]` | `<RuleCard>` + `<VoteSheet>` + `<RuleExceptionsEditor>` + `<RuleHistoryLog>` |
| `/g/[gid]/plata` | `<BalanceHero>` + `<FundCard>` + `<Tabs>` con multas/gastos/pots |

### Schemas Zod compartidos

```
lib/schemas/
  ids.ts          # GroupId, EventId, UserId — branded types con validación uuid
  money.ts        # MoneyAmount (numeric, ≥0, max 12.2)
  enums.ts        # RsvpStatus, VoteSubjectType, RuleTriggerType
```

### Naming conventions

- Components: `PascalCase.tsx`, default export
- Hooks: `useXxx.ts`, named export
- Server actions: `actions.ts`, named camelCase exports
- Queries: `queries.ts`, prefijo `get` / `list`
- Schemas: `XxxSchema` y type `Xxx = z.infer<typeof XxxSchema>`
- RPCs SQL: `snake_case`

---

## 8. Cron, Rule Engine & Push Pipeline

### pg_cron schedule (en `00006_cron_jobs.sql`)

```sql
create extension if not exists pg_cron;

select cron.schedule('mark_no_shows',     '*/5  * * * *', $$ select public.mark_no_shows()           $$);
select cron.schedule('auto_close_votes',  '*/5  * * * *', $$ select public.auto_close_votes()        $$);
select cron.schedule('enqueue_reminders', '*/15 * * * *', $$ select public.enqueue_due_reminders()   $$);
select cron.schedule('roll_event_series', '0   * * * *', $$ select public.auto_roll_due_series()    $$);
select cron.schedule('dispatch_push',     '*/2  * * * *',
  $$ select net.http_post(
       url := current_setting('app.edge_dispatch_push_url'),
       headers := jsonb_build_object('Authorization','Bearer '||current_setting('app.cron_secret'),
                                     'Content-Type','application/json')
     ) $$);
```

### RPCs nuevas

| RPC | Propósito |
|---|---|
| `mark_no_shows()` | Marca `att.no_show=true` para events vencidos sin arrived_at |
| `auto_close_votes()` | Cierra votes con `closes_at < now()` invocando `close_vote(id)` |
| `enqueue_due_reminders()` | Inserta filas en `notifications` para reminders programados |
| `auto_roll_due_series()` | Crea evento siguiente del grupo si default_day y rotation habilitados |
| `roll_event_series(p_event_id)` | Versión per-evento (llamada inline al cerrar evento) |
| `register_push_subscription(endpoint, p256dh, auth)` | Upsert en `push_subscriptions` |
| `mark_notification_read(p_id)` | Marca `read_at = now()` |
| `enqueue_event_reminders(p_event_id)` | Inserta reminders específicos del evento |

Cada una: logea en `job_runs`, idempotente vía existence checks o `ON CONFLICT DO NOTHING`, `security definer` con revoke from public/anon.

### Edge Function: `dispatch-push`

```
supabase/functions/dispatch-push/
  index.ts              # Deno: lee notifs unsent, llama web-push, marca sent_at
  webpush.ts            # helper VAPID (ESM web-push port)
  config.ts
```

Lógica:
1. Auth: header bearer == `CRON_SECRET` (env)
2. `select * from notifications where sent_at is null and created_at > now() - '1 day' limit 200`
3. Por cada notif: `select push_subscriptions where user_id = n.user_id`
4. `webpush.send(subscription, { title, body, url, badge_count })`
   - 410 Gone → delete subscription
   - 4xx other → log, update last_seen_at
5. `update notifications set sent_at = now() where id in (...)`

Variables:
```
CRON_SECRET=<random>
VAPID_PUBLIC_KEY=<gen>
VAPID_PRIVATE_KEY=<gen>
VAPID_SUBJECT=mailto:jose.mizrahi@quimibond.com
```

### Service worker (`public/sw.js`)

```js
// 1. push event: parsea data, muestra notification con title/body/icon/url
// 2. notificationclick: abre/foco la URL del notification
// 3. Sin caching de assets v1 — Vercel ya hace edge cache
```

### Reminder rules

| Kind | Cuándo | Para quién |
|---|---|---|
| `rsvp_deadline_2h` | `rsvp_deadline - now() between 0 and 2h` | rsvp_status = 'pending' |
| `event_tomorrow` | `starts_at - now() between 12h and 36h` | rsvp_status = 'going' |
| `vote_closing_soon` | `closes_at - now() between 0 and 6h` | members que no votaron |
| `fine_issued` | inmediato post `evaluate_event_rules` (trigger) | el multado |
| `vote_opened` | inmediato post `create_vote` (trigger) | todos los elegibles |
| `event_no_show` | inmediato post `mark_no_shows` | el no-show + admins |
| `fine_appeal_decided` | inmediato post `close_vote` para fine_appeal | el multado |

### Auto-rollout de eventos (idempotente)

```sql
create or replace function public.roll_event_series(p_event_id uuid) returns uuid as $$
declare e public.events; g public.groups; v_next timestamptz; v_next_id uuid;
begin
  select * into e from public.events where id = p_event_id;
  select * into g from public.groups where id = e.group_id;
  if not g.rotation_enabled or g.default_day_of_week is null then return null; end if;

  v_next := date_trunc('week', e.starts_at at time zone g.timezone)
            + (g.default_day_of_week || ' days')::interval
            + g.default_start_time
            + interval '1 week';
  v_next := v_next at time zone g.timezone;

  -- Idempotencia
  select id into v_next_id from public.events where parent_event_id = e.id limit 1;
  if v_next_id is not null then return v_next_id; end if;

  v_next_id := public.create_event(
    e.group_id, v_next, null, g.default_location, null, null,
    e.cycle_number + 1, v_next - interval '24 hours'
  );
  update public.events set parent_event_id = e.id where id = v_next_id;
  return v_next_id;
end;
$$ language plpgsql security definer set search_path = public;
```

### Observabilidad: vista `cron_health`

```sql
create view public.cron_health with (security_invoker = true) as
select job_name,
       max(started_at) as last_run,
       max(finished_at) as last_finish,
       extract(epoch from (now() - max(started_at)))/60 as minutes_since,
       sum(case when error is not null then 1 else 0 end) as recent_errors
from public.job_runs
where started_at > now() - interval '1 day'
group by job_name;
```

`/g/[gid]/mas/settings` muestra a admins "Última ejecución de jobs". Si algo lleva >30 min sin correr, alert visual.

---

## 9. Testing Strategy

### Pirámide

```
Playwright e2e          10–15 flows críticos mobile
Vitest integration      ~30 server actions + queries (DB real, RLS habilitado)
Vitest unit             ~50 schemas, helpers, rule preset builders
SQL harness             ~20 RLS isolation, rule engine, balance view
```

### Capa SQL & RLS (donde más duele)

Setup: `supabase/tests/_harness.sql` crea 3 users (alice/bob/carol), 2 grupos disjuntos, sembrado predecible. Cada test corre en transacción + rollback.

```
supabase/tests/
  _harness.sql
  rls/
    profiles_visibility.test.sql
    cross_group_isolation.test.sql        # bob (group A) NO ve nada de group B
    members_admin_only.test.sql
    fines_user_can_pay_self.test.sql
    vote_ballots_locked_when_closed.test.sql   # bug fix
  rules/
    late_arrival_tiered.test.sql                # 0/30/45/60 min → fines correctas
    late_arrival_tz_dst.test.sql                # bug fix tz, prueba con America/Mexico_City
    no_confirmation_deadline.test.sql
    same_day_cancel.test.sql
    no_show_no_double.test.sql                  # idempotencia
    rule_exceptions_respected.test.sql
  rpcs/
    create_event_rotation.test.sql              # host se asigna en orden
    pay_fine_to_fund.test.sql
    close_vote_passes_quorum.test.sql
    close_vote_threshold_edge.test.sql           # 0 yes 0 no all abstain
    propose_rule_activates_on_pass.test.sql
    create_expense_shares_sum.test.sql           # error si no balancea
  views/
    group_balances_full_cycle.test.sql          # gastos + payments + fines + pots
  cron/
    mark_no_shows_idempotent.test.sql
    auto_close_votes_idempotent.test.sql
    roll_event_series_no_dup.test.sql           # llamar 2x crea solo 1 hijo
```

### Capa server actions / queries (Vitest integration)

```
features/<feature>/__tests__/actions.int.test.ts
features/<feature>/__tests__/queries.int.test.ts
```

DB: branch de Supabase para CI o local con `supabase start`. Reset con truncate cascade en `_harness`.

### Capa unit (Vitest)

- Schemas Zod (parse + reject)
- Rule preset builders (`features/rules/presets.ts`)
- Money helpers (formato MXN, suma con redondeo)
- Date helpers (next event date desde cadencia + tz)
- Tally calculator
- Balance reducer cliente (optimistic UI)

### Capa e2e (Playwright mobile)

Solo flows que mueven dinero o cambian estado. `device: 'iPhone 13'` y `device: 'Pixel 7'`.

```
e2e/
  01-onboarding.spec.ts          # signup phone OTP (mock) + crear grupo + invitar
  02-join-group.spec.ts          # invite_code + queda en orden 2
  03-rsvp-and-checkin.spec.ts
  04-rule-engine-late.spec.ts    # crear regla + check-in tarde + ver multa
  05-pay-fine-to-fund.spec.ts
  06-vote-rule-proposal.spec.ts  # proponer + 3 votos → activación
  07-pot-with-iou.spec.ts
  08-splitwise-cycle.spec.ts     # gasto $300 ÷ 3 + payment + balance neto = 0
  09-fine-appeal.spec.ts         # apelar + comité vota + waive
  10-recurring-event.spec.ts     # cerrar → próximo se crea con host rotado
```

Mock providers para SMS/email OTP en CI: Supabase test mode (`testOtp`).

### CI (GitHub Actions)

```yaml
jobs:
  test:
    steps:
      - supabase start
      - supabase migration up
      - npm run test:unit
      - npm run test:sql
      - npm run test:int
      - npm run build              # tsc + next build (debe pasar)
      - npx playwright install --with-deps
      - npm run test:e2e
```

DoD por PR:
- `npm run build` ✓
- `tsc --noEmit` ✓
- `npm run test` ✓ (unit + int + sql)
- ESLint ✓ (incluye `boundaries`)
- Si toca SQL → `npm run test:sql` ✓
- Si toca UI → al menos 1 e2e relevante green
- `axe` accessibility check pasa en e2e

### Lo que NO testeamos en v1

- Push end-to-end (mockeable, no necesario)
- Service worker offline behavior
- Edge function `dispatch-push` (manual en preview, structured logs en `job_runs`)
- Visual regression (Chromatic / Percy) — overkill ahora

---

## 10. Out of Scope (v1)

- Fotos / comprobantes en gastos y pagos de multas
- WhatsApp Business API (OTP + templates)
- iCal export / Google Calendar sync
- Múltiples comités con permisos distintos
- Apuestas paralelas dentro de pots
- Grupos con jerarquía (sub-comités, sub-grupos)
- Internacionalización fuera de es-MX
- Mutaciones offline con queue
- Dark mode override por grupo
- Configurar formato de moneda más allá de MXN/USD/EUR
- Reportes / exports a CSV
- Audit log dedicado (las tablas ya guardan trazas vía `marked_by`, `paid_at`, `issued_by`)

---

## 11. v2 Roadmap (orden tentativo)

1. **WhatsApp templates** para reminders + WhatsApp OTP (reemplaza SMS Twilio)
2. **Fotos** en gastos y comprobantes de pago
3. **Push refinement**: digest diario en vez de uno por evento
4. **iCal export** del calendar del grupo
5. **Reportes**: CSV de balance histórico, fines por miembro, fund usage
6. **Múltiples grupos en una notif** — bell consolida cross-group
7. **Audit log** explícito (quién hizo qué cuándo)
8. **i18n**: en + pt-BR cuando haya demanda real

---

## 12. Open Questions / Decisions Pending

Ninguna que bloquee implementación. Los siguientes detalles se resolverán durante writing-plans:

- Versionado y nombres exactos de migrations (corren tests primero)
- Forma exacta de los Zod schemas por feature
- Layout exacto de cada pantalla (wireframes ad-hoc en cada PR)
- Modelo de manifest PWA (icons, splash, theme_color)
- Tokens de Tailwind v4 finales (esperar al primer shadcn install)
