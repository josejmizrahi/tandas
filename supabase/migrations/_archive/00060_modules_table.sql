-- 00060 — Server-side `modules` catalog: makes ModuleRegistry a real
-- primitive instead of an iOS-only declaration.
--
-- Plans/Active/Primitives.md § 3 named the tripleta as
--   Module declaration + ModuleRegistry + CapabilityResolver
-- and called it "done" — but the whole thing lived in iOS only:
-- `ios/.../PlatformModules/V1Modules.swift` was the source of truth,
-- and the server's `set_group_module` (00057) hardcoded its own copy
-- of the dep closures inside the function body. Two consequences:
--
--   1. Adding a module requires lockstep edits in iOS + a SQL
--      migration that reproduces the closure jsonb. Drift is latent.
--   2. Edge functions / future web companion / external tools have
--      no API to ask "what modules exist?" — they'd have to read
--      iOS source code or replicate the catalog.
--
-- This migration introduces `public.modules` as the canonical
-- registry server-side, seeds the 5 V1 modules from the iOS catalog
-- verbatim, and exposes `public.list_modules()` so iOS becomes a pure
-- consumer. 00061 follows up by rewriting `set_group_module` to
-- compute cascades dynamically from the new table (kills the
-- hardcoded jsonb closures in 00057).
--
-- RLS: read-only for authenticated users. Writes happen via migration
-- only — modules are configuration, not data the app mutates.

create table if not exists public.modules (
  id                          text primary key,
  name                        text not null,
  description                 text,
  provided_rules              text[] not null default '{}',
  provided_resource_types     text[] not null default '{}',
  provided_system_event_types text[] not null default '{}',
  provided_tabs               text[] not null default '{}',
  dependencies                text[] not null default '{}',
  conflicts_with              text[] not null default '{}',
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

comment on table public.modules is
  'Canonical catalog of platform modules. Source of truth for the ModuleRegistry primitive. Seeded by migrations; iOS reads via list_modules().';
comment on column public.modules.dependencies is
  'Direct dependencies (module ids that must be enabled when this one is). Transitive closure computed at call time in set_group_module.';
comment on column public.modules.conflicts_with is
  'Direct conflicts (module ids that must be disabled when this one is). V1 has no conflicts; Phase 2 modules will use this.';

alter table public.modules enable row level security;

drop policy if exists "modules_read_authenticated" on public.modules;
create policy "modules_read_authenticated"
  on public.modules
  for select
  to authenticated
  using (true);

-- =========================================================
-- Seed the 5 V1 modules
-- =========================================================
-- Mirrors `ios/.../PlatformModules/V1Modules.swift` verbatim. Provided
-- arrays use camelCase strings matching the Swift enum raw values
-- (SystemEventType, ResourceType, etc.) so iOS can decode without
-- transformation.

insert into public.modules (
  id, name, description,
  provided_rules, provided_resource_types,
  provided_system_event_types, provided_tabs,
  dependencies, conflicts_with
) values
  (
    'basic_fines',
    'Multas básicas',
    'Multas monetarias automáticas por reglas violadas: llegar tarde, no avisar, no presentarse.',
    array['dinner_late_arrival','dinner_no_response','dinner_same_day_cancel','dinner_no_show','dinner_host_no_menu']::text[],
    array[]::text[],
    array['fineOfficialized','finePaid','appealCreated','appealResolved']::text[],
    array[]::text[],
    array['rsvp','check_in']::text[],
    array[]::text[]
  ),
  (
    'rotating_host',
    'Host rotativo',
    'El rol de host rota entre miembros automáticamente al cerrar cada evento.',
    array[]::text[],
    array[]::text[],
    array['positionChanged']::text[],
    array[]::text[],
    array[]::text[],
    array[]::text[]
  ),
  (
    'rsvp',
    'RSVP',
    'Respuestas de asistencia: voy, tal vez, no voy. Auto-creadas al crearse un evento.',
    array[]::text[],
    array[]::text[],
    array['rsvpSubmitted','rsvpChangedSameDay','rsvpDeadlinePassed']::text[],
    array[]::text[],
    array[]::text[],
    array[]::text[]
  ),
  (
    'check_in',
    'Check-in',
    'Registro de llegada al evento: self check-in, manual o QR. Habilita reglas de tardanza.',
    array[]::text[],
    array[]::text[],
    array['checkInRecorded','checkInMissed']::text[],
    array[]::text[],
    array['rsvp']::text[],
    array[]::text[]
  ),
  (
    'appeal_voting',
    'Apelación con votación',
    'Si un miembro apela una multa, el grupo vota anónimamente si cancelarla.',
    array[]::text[],
    array[]::text[],
    array['voteOpened','voteCast','voteResolved']::text[],
    array[]::text[],
    array['basic_fines']::text[],
    array[]::text[]
  )
on conflict (id) do nothing;

-- =========================================================
-- list_modules() — RPC for clients
-- =========================================================
-- Returns the full catalog. SECURITY DEFINER so any authenticated
-- user can read regardless of RLS evolution; the catalog is public
-- per-app information.

create or replace function public.list_modules()
returns setof public.modules
language sql
security definer
stable
set search_path = public
as $$
  select * from public.modules order by id;
$$;

revoke execute on function public.list_modules() from public, anon;
grant execute on function public.list_modules() to authenticated;

comment on function public.list_modules() is
  'Returns the full module catalog. Consumed by iOS LiveModuleRegistry to populate the registry on app boot — replaces the hardcoded V1Modules.swift list as the runtime source of truth.';
