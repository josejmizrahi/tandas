-- 00165 — Server-side capabilities catalog (Constitution audit Gap 3).
--
-- Why
-- ===
-- Constitution Article 5: "Capabilities son primitivas de comportamiento.
-- Universales, platform-level, ~15-20 unidades atómicas. Catálogo fijo;
-- modules las componen, no las redefinen." Until now the catalog lived
-- exclusively in iOS code (`CapabilityResolver.swift` +
-- `CapabilityCatalog.swift`). `modules.provided_capability_blocks` is a
-- text[] column with zero referential integrity — a module migration
-- could declare a typo'd capability id and Postgres wouldn't complain.
--
-- This migration ships the server-side catalog as a configuration table
-- mirroring the canonical V1 catalog from
-- `RuulCore/Capabilities/CapabilityCatalog.swift` (commit ccbdf16-era).
-- iOS remains the source of truth for behavior; the DB row is a
-- runtime catalog that downstream tools (RLS quals, edge functions,
-- analytics dashboards, future FK enforcement) can query.
--
-- What ships
-- ==========
-- - `public.capabilities` table: id (text PK), display_name, summary,
--   status ('stable' | 'incomplete'), enabled_resource_types text[],
--   dependencies text[].
-- - Seed: 28 capabilities matching the iOS catalog. Status tracks the
--   `CapabilityStatus` field declared on each block in iOS.
-- - RLS: read-only for any authenticated caller. No writes from clients.
-- - Comment on `modules.provided_capability_blocks` pointing readers
--   to this catalog as the canonical reference.
--
-- Out of scope
-- ============
-- - FK enforcement on `modules.provided_capability_blocks` array
--   elements. Postgres doesn't support FKs on array elements directly;
--   would need a junction table or trigger. Defer to post-Beta when
--   the catalog stabilises and module seeding is more dynamic.
-- - Sync test that iOS catalog matches the DB seed. Worth adding to
--   the iOS test suite once the parity rules settle.
-- - Doctrine cleanup: Constitution.md Article 5 lists a slightly
--   different ~21-item subset. The DB matches actual code. Doc update
--   is a separate cleanup.

create table if not exists public.capabilities (
  id                       text primary key,
  display_name             text not null,
  summary                  text not null,
  status                   text not null default 'stable'
    check (status in ('stable', 'incomplete')),
  enabled_resource_types   text[] not null default '{}',
  dependencies             text[] not null default '{}',
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

comment on table public.capabilities is
  'Canonical platform capability catalog (Constitution Article 5). Mirrors the iOS CapabilityCatalog. Configuration: fixed at platform level, not group-scoped. modules.provided_capability_blocks references these ids by string.';

alter table public.capabilities enable row level security;

drop policy if exists capabilities_read_authenticated on public.capabilities;
create policy capabilities_read_authenticated on public.capabilities
  for select using (auth.role() = 'authenticated');

-- =============================================================================
-- Seed: 28 V1 capabilities from RuulCore/Capabilities/CapabilityCatalog.swift
-- =============================================================================

insert into public.capabilities (id, display_name, summary, status, enabled_resource_types, dependencies) values
  ('rsvp',         'RSVP',             'Los miembros confirman si van a venir.', 'stable',     array['event'],                                   array[]::text[]),
  ('check_in',     'Check-in',         'Registro de llegada al evento.',          'stable',     array['event'],                                   array['rsvp']),
  ('schedule',     'Horario',          'Fecha, hora y duración.',                  'stable',     array['event','slot'],                            array[]::text[]),
  ('recurrence',   'Repetir',          'Genera ocurrencias automáticamente.',      'stable',     array['event','slot','fund'],                     array['schedule']),
  ('rotation',     'Rotación',         'Asigna rol/turno rotativamente.',          'stable',     array['event','slot'],                            array['participants']),
  ('assignment',   'Asignación',       'Asigna una tarea a un miembro.',           'incomplete', array['event','slot'],                            array[]::text[]),
  ('participants', 'Participantes',    'Define quién está incluido por default.',  'incomplete', array['event','slot'],                            array[]::text[]),
  ('attendance',   'Asistencia',       'Registro de quién asistió de hecho.',      'stable',     array['event','slot'],                            array[]::text[]),
  ('deadline',     'Fecha límite',     'Hora a la que algo debe estar resuelto.',  'stable',     array['event','slot'],                            array[]::text[]),
  ('approval',     'Aprobación',       'Requiere aprobación antes de efecto.',     'incomplete', array['slot','right'],                            array[]::text[]),
  ('money',        'Dinero',           'Gastos, aportaciones, multas.',            'stable',     array['event','slot','fund'],                     array['ledger']),
  ('ledger',       'Ledger',           'Asientos contables atómicos.',             'stable',     array['event','slot','fund'],                     array[]::text[]),
  ('voting',       'Votación',         'Decisión colectiva con quórum y umbral.',  'incomplete', array['event','fund','asset','space','slot','right'], array[]::text[]),
  ('rules',        'Reglas',           'Qué pasa automáticamente cuando algo sucede.', 'stable', array['event','slot','fund'],                     array[]::text[]),
  ('consequence',  'Consecuencias',    'Las reglas pueden generar multas/avisos.', 'incomplete', array['event','slot','fund'],                     array['rules']),
  ('appeal',       'Apelación',        'Permite disputar una multa o sanción.',    'stable',     array['event'],                                   array['voting','consequence']),
  ('swap',         'Cambios',          'Intercambia slots o turnos entre miembros.','incomplete', array['slot'],                                    array[]::text[]),
  ('capacity',     'Cupo',             'Límite de cuántos miembros caben.',        'stable',     array['event','slot','asset','right'],            array[]::text[]),
  ('guest_access', 'Invitados',        'Miembros pueden traer acompañantes.',      'incomplete', array['event','slot','asset'],                    array[]::text[]),
  ('booking',      'Reservas',         'Miembros reservan slots/recursos.',        'incomplete', array['slot','asset'],                            array['schedule']),
  ('expiration',   'Expira',           'El recurso se libera/cierra al expirar.',  'stable',     array['slot','right'],                            array[]::text[]),
  ('cancellation', 'Cancelación',      'Quién puede cancelar y con qué anticipación.', 'incomplete', array['event','slot'],                        array[]::text[]),
  ('reminder',     'Recordatorios',    'Avisa antes de fecha límite o evento.',    'incomplete', array['event','slot','fund'],                     array[]::text[]),
  ('status',       'Estado',           'Lifecycle del recurso.',                   'stable',     array['event','fund','asset','space','slot','right'], array[]::text[]),
  ('description',  'Descripción',      'Texto libre del recurso.',                 'stable',     array['event','fund','asset','space','slot','right'], array[]::text[]),
  ('host_actions', 'Acciones del host','Panel host-only.',                          'stable',     array['event'],                                   array[]::text[]),
  ('location',     'Lugar',            'Dirección o sitio físico.',                 'stable',     array['event','slot','asset'],                    array[]::text[]),
  ('history',      'Historial',        'Bitácora derivada de system_events.',      'stable',     array['event','fund','asset','space','slot','right'], array[]::text[])
on conflict (id) do update set
  display_name           = excluded.display_name,
  summary                = excluded.summary,
  status                 = excluded.status,
  enabled_resource_types = excluded.enabled_resource_types,
  dependencies           = excluded.dependencies,
  updated_at             = now();

comment on column public.modules.provided_capability_blocks is
  'Array of capability ids this module exposes. Each element must exist in public.capabilities.id (Constitution Article 5; FK enforcement deferred — see mig 00165).';

-- updated_at trigger for in-place edits to the catalog
drop trigger if exists capabilities_set_updated_at on public.capabilities;
create trigger capabilities_set_updated_at
  before update on public.capabilities
  for each row execute function public.set_updated_at();
