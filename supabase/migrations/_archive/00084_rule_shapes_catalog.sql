-- 00084 — Rule shapes catalog (Phase 4 in-event rules slice 2 — R1).
--
-- Founder framing 2026-05-10: rules must be runtime-declarative. Slice 1
-- shipped iOS-side hardcoded TriggerKind / consequence enums to gate the
-- form, which violates that principle — adding a new trigger required an
-- iOS release. This catalog moves shape definitions server-side so the
-- iOS form renders dynamically from `list_rule_shapes()` rows.
--
-- A "shape" is a single trigger, condition, or consequence the rule
-- engine understands. Each row carries the human-language labels, valid
-- scope levels, valid resource types, and the config schema the iOS
-- form should render to collect user input.
--
-- Forward compatibility: adding a new shape is now a single INSERT into
-- `rule_shapes` + an evaluator implementation in `_shared/ruleEngine.ts`.
-- No iOS change required for the form to surface it. Disabling a shape
-- (e.g. deprecating one trigger) is `update rule_shapes set enabled = false`.

create table if not exists public.rule_shapes (
  id                    text primary key,
  kind                  text not null check (kind in ('trigger','condition','consequence')),
  label_es              text not null,
  summary_es            text,
  icon                  text,
  -- Empty array = applies to all scope levels.
  valid_scopes          text[] not null default '{}',
  -- Empty array = applies to all resource types (or N/A for group scope).
  valid_resource_types  text[] not null default '{}',
  -- Array of { key, kind, label_es, optional, placeholder?, defaultValue?, min?, max?, enumValues? }.
  -- See iOS RuleShapeField.swift for the decoder. Empty array = no config
  -- input needed beyond selecting the shape.
  config_fields         jsonb  not null default '[]'::jsonb,
  sort_order            int    not null default 0,
  enabled               boolean not null default true,
  created_at            timestamptz not null default now()
);

create index if not exists idx_rule_shapes_kind_sort
  on public.rule_shapes(kind, sort_order)
  where enabled = true;

comment on table public.rule_shapes is
  'Catalog of available rule triggers/conditions/consequences. iOS rule-builder form renders dynamically from list_rule_shapes(). Adding a shape = INSERT here + evaluator in ruleEngine.ts; no client release required.';

-- =========================================================
-- Seed V1 shapes
-- =========================================================
-- TRIGGERS — V1 implemented per SystemEventType+Extensions.swift
insert into public.rule_shapes (id, kind, label_es, summary_es, icon, valid_scopes, valid_resource_types, config_fields, sort_order)
values
  ('checkInRecorded',
   'trigger',
   'Cuando alguien llega tarde',
   'Se dispara cuando un miembro hace check-in después de la hora de inicio del evento.',
   'clock.badge.exclamationmark',
   array['resource','series'],
   array['event'],
   '[]'::jsonb,
   10),
  ('rsvpChangedSameDay',
   'trigger',
   'Cuando alguien cancela el mismo día',
   'Se dispara cuando un miembro cambia su RSVP a "no voy" el día del evento.',
   'person.crop.circle.badge.xmark',
   array['resource','series'],
   array['event'],
   '[]'::jsonb,
   20),
  ('eventClosed',
   'trigger',
   'Al cerrar el evento',
   'Se dispara cuando el host cierra el evento. Todos los presentes/ausentes ya están registrados.',
   'checkmark.seal',
   array['resource','series','group'],
   array['event'],
   '[]'::jsonb,
   30),
  ('hoursBeforeEvent',
   'trigger',
   'Horas antes del evento',
   'Se dispara N horas antes de la hora de inicio. El cron evalúa cada minuto.',
   'hourglass',
   array['resource','series','group'],
   array['event'],
   '[{"key":"hours","kind":"int","label_es":"¿Cuántas horas antes?","placeholder":"24","min":1,"max":168,"defaultValue":24}]'::jsonb,
   40),
  ('rsvpDeadlinePassed',
   'trigger',
   'Al pasar la fecha límite de RSVP',
   'Se dispara cuando vence el deadline de RSVP del evento.',
   'calendar.badge.exclamationmark',
   array['resource','series','group'],
   array['event'],
   '[]'::jsonb,
   50);

-- CONDITIONS — V1 evaluators
insert into public.rule_shapes (id, kind, label_es, summary_es, icon, valid_scopes, valid_resource_types, config_fields, sort_order)
values
  ('alwaysTrue',
   'condition',
   'Sin condiciones extra',
   'La regla aplica cada vez que se dispara el trigger.',
   'circle.fill',
   array[]::text[],
   array[]::text[],
   '[]'::jsonb,
   10),
  ('checkInMinutesLate',
   'condition',
   'Sólo si la tardanza supera N minutos',
   'Filtra: la regla aplica únicamente cuando el miembro llegó más de N minutos tarde.',
   'timer',
   array[]::text[],
   array[]::text[],
   '[{"key":"minutes","kind":"int","label_es":"Minutos de tolerancia","placeholder":"15","min":1,"max":240,"defaultValue":15}]'::jsonb,
   20);

-- CONSEQUENCES — V1 evaluators (only `fine` is implemented end-to-end)
insert into public.rule_shapes (id, kind, label_es, summary_es, icon, valid_scopes, valid_resource_types, config_fields, sort_order)
values
  ('fine',
   'consequence',
   'Cobrar una multa',
   'Emite una multa al miembro que disparó el trigger.',
   'banknote',
   array[]::text[],
   array[]::text[],
   '[{"key":"amount","kind":"currency","label_es":"Monto en MXN","placeholder":"200","min":1,"max":1000000,"defaultValue":200}]'::jsonb,
   10);

-- =========================================================
-- RPC: list_rule_shapes
-- =========================================================
create or replace function public.list_rule_shapes()
returns setof public.rule_shapes
language sql security definer set search_path = public stable as $$
  select * from public.rule_shapes where enabled = true order by kind, sort_order;
$$;

revoke execute on function public.list_rule_shapes() from public, anon;
grant  execute on function public.list_rule_shapes() to authenticated;

comment on function public.list_rule_shapes() is
  'Returns the active rule shape catalog. iOS reads this at boot (mirroring list_modules) and renders the rule builder form from the rows.';

-- =========================================================
-- RLS — read-only for authenticated; no direct writes
-- =========================================================
alter table public.rule_shapes enable row level security;

create policy "rule_shapes_read_authenticated"
  on public.rule_shapes
  for select to authenticated
  using (true);

-- No write policy — catalog is platform-managed via migrations.
