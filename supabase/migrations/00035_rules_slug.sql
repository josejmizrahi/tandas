-- 00035 — Stable cross-group slug for rules.
--
-- Audit doc § 5.3 #10 (Riesgo 6). Until now, modules linked rules by
-- display string in `GroupModule.providedRules` (V1Modules.swift).
-- Display strings break the link as soon as someone localizes copy or
-- per-group renames a rule.
--
-- This migration introduces `public.rules.slug` as the new stable
-- identifier:
--   - Optional (NULL) for user-authored rules created via propose_rule
--     after V1 (no slug to inherit).
--   - Set automatically by `seed_dinner_template_rules` for the 5
--     dinner_recurring template rules — values mirror the existing
--     legacy `code` column (`dinner_late_arrival`, etc.) so backfill
--     is a straight copy.
--   - Carried in `templates.config.defaultRules[].slug` as the canonical
--     source. iOS reads slugs at materialize time and writes them on
--     insert.
--
-- Why a new column instead of reusing `code`:
--   `code` was deprecated in 00033 and is scheduled for DROP pre-Fase 2.
--   Adding `slug` lets us drop `code` without bridging.
--
-- Index on (group_id, slug) supports analytics queries
--   "how many fires came from rules of slug X across all groups".
-- Not unique because:
--   - NULL slugs on user-authored rules (multiple per group).
--   - Cohabitation period might allow re-seeding (idempotent guard
--     prevents that today, but no need to enforce at schema level).

-- =============================================================================
-- Schema change
-- =============================================================================

alter table public.rules
  add column if not exists slug text;

comment on column public.rules.slug is
  'Stable cross-group identifier inherited from the originating template rule (e.g. dinner_late_arrival). NULL for user-authored rules. Survives display rename + i18n.';

create index if not exists rules_slug_idx
  on public.rules (group_id, slug)
  where slug is not null;

-- =============================================================================
-- Backfill from legacy `code`
-- =============================================================================

-- Existing rows seeded via `seed_dinner_template_rules` (00015) have
-- `code` populated with the canonical slug. Copy as-is. Rows from
-- propose_rule (user-authored) have `code = format('rule_%s', uuid)`
-- which is per-instance — leave NULL since it isn't a stable
-- cross-group identifier.
update public.rules
set    slug = code
where  slug is null
  and  code in (
    'dinner_late_arrival',
    'dinner_no_response',
    'dinner_same_day_cancel',
    'dinner_no_show',
    'dinner_host_no_menu'
  );

-- =============================================================================
-- Update seed_dinner_template_rules to write slug
-- =============================================================================
-- Rewrite of 00015 — same body, plus `slug` column on each row.
-- Idempotent guard unchanged.

create or replace function public.seed_dinner_template_rules(
  p_group_id uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;

  if exists (
    select 1 from public.rules
     where group_id = p_group_id
       and consequences <> '[]'::jsonb
  ) then
    return;
  end if;

  return query
  insert into public.rules (
    group_id, slug,
    code, title, description, trigger, action,
    name, is_active, conditions, consequences,
    status, enabled, proposed_by
  )
  values
  (
    p_group_id, 'dinner_late_arrival',
    'dinner_late_arrival',
    'Llegada tardía',
    'Multa escalonada por llegar después de la hora de la cena',
    jsonb_build_object('eventType', 'checkInRecorded', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Llegada tardía',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'checkInMinutesLate', 'config', jsonb_build_object('thresholdMinutes', 0))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('baseAmount', 200, 'stepAmount', 50, 'stepMinutes', 30))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_no_response',
    'dinner_no_response',
    'No confirmó a tiempo',
    'Multa para quien no respondió RSVP antes del cierre',
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'No confirmó a tiempo',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'pending'))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_same_day_cancel',
    'dinner_same_day_cancel',
    'Cancelación mismo día',
    'Multa por cancelar la asistencia el mismo día del evento',
    jsonb_build_object('eventType', 'rsvpChangedSameDay', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Cancelación mismo día',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'alwaysTrue', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_no_show',
    'dinner_no_show',
    'No-show',
    'Multa para quien confirmó asistencia pero no llegó',
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 300),
    'No-show',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'going')),
      jsonb_build_object('type', 'checkInExists',     'config', jsonb_build_object('exists', false))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 300))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_host_no_menu',
    'dinner_host_no_menu',
    'Anfitrión sin menú',
    'Multa para el host si no llenó la descripción 24h antes',
    jsonb_build_object('eventType', 'hoursBeforeEvent', 'config', jsonb_build_object('hours', 24)),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Anfitrión sin menú',
    false,
    jsonb_build_array(
      jsonb_build_object('type', 'eventDescriptionMissing', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', false, uid
  )
  returning *;
end;
$$;

revoke execute on function public.seed_dinner_template_rules(uuid) from public, anon;
grant  execute on function public.seed_dinner_template_rules(uuid) to authenticated;

-- =============================================================================
-- Update templates.config.defaultRules to include slug per rule
-- =============================================================================
-- Rebuild the defaultRules array for recurring_dinner with slug field
-- on each entry. iOS reads via TemplateConfig.defaultRules (each
-- TemplateRule.slug is optional). Order matches 00021 source.

update public.templates
set config = jsonb_set(
  config,
  '{defaultRules}',
  jsonb_build_array(
    jsonb_build_object(
      'slug',          'dinner_late_arrival',
      'name',          'Llegada tardía',
      'description',   'Multa escalada por minuto de retraso al check-in.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'checkInRecorded'),
      'conditions',    jsonb_build_array(
        jsonb_build_object(
          'type', 'checkInMinutesLate',
          'config', jsonb_build_object('thresholdMinutes', 0)
        )
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object(
            'baseAmount',  200,
            'stepAmount',  50,
            'stepMinutes', 30
          )
        )
      )
    ),
    jsonb_build_object(
      'slug',          'dinner_no_response',
      'name',          'No confirmó a tiempo',
      'description',   'Multa por no responder RSVP antes del cierre del evento.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'eventClosed'),
      'conditions',    jsonb_build_array(
        jsonb_build_object(
          'type', 'responseStatusIs',
          'config', jsonb_build_object('status', 'pending')
        )
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 200)
        )
      )
    ),
    jsonb_build_object(
      'slug',          'dinner_same_day_cancel',
      'name',          'Cancelación mismo día',
      'description',   'Multa por cambiar a "no voy" el día del evento.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'rsvpChangedSameDay'),
      'conditions',    jsonb_build_array(
        jsonb_build_object('type', 'alwaysTrue', 'config', jsonb_build_object())
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 200)
        )
      )
    ),
    jsonb_build_object(
      'slug',          'dinner_no_show',
      'name',          'No se presentó',
      'description',   'Multa por confirmar y no llegar (sin check-in).',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'eventClosed'),
      'conditions',    jsonb_build_array(
        jsonb_build_object(
          'type', 'responseStatusIs',
          'config', jsonb_build_object('status', 'going')
        ),
        jsonb_build_object(
          'type', 'checkInExists',
          'config', jsonb_build_object('exists', false)
        )
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 500)
        )
      )
    ),
    jsonb_build_object(
      'slug',          'dinner_host_no_menu',
      'name',          'Anfitrión sin descripción',
      'description',   'Multa al host si no propuso menú/lugar 24h antes.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object(
        'eventType', 'hoursBeforeEvent',
        'config',    jsonb_build_object('hours', 24)
      ),
      'conditions',    jsonb_build_array(
        jsonb_build_object('type', 'memberIsHost', 'config', jsonb_build_object()),
        jsonb_build_object('type', 'eventDescriptionMissing', 'config', jsonb_build_object())
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 100)
        )
      )
    )
  )
)
where id = 'recurring_dinner';

-- NOTE: this migration preserves the parity-drift between the templates
-- table seed (00021) and the seed RPC (00015) — they still differ in
-- amounts, name spellings, and the use of `memberIsHost`. Reconciling
-- that drift is audit item 7b and out of scope for this slug migration.
-- The slug values themselves are identical across both, which is what
-- makes the cross-group `providedRules` link stable.
