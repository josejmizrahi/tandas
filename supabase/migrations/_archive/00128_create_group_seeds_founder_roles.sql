-- 00128 — create_group_with_admin seeds the founder's `roles` jsonb +
-- one-time backfill for legacy admins missing 'founder'.
--
-- Background
-- ==========
-- Tier 0.5 audit 2026-05-12 surfaced a real prod gap:
--
--   select count(*) filter (where role='admin'
--                             and not coalesce(roles ? 'founder', false))
--   from public.group_members where active;
--   → 2 of 4 active admins
--
-- Mig 00027_can_modify_rules_use_roles_jsonb.sql reads the `roles`
-- jsonb (line 37 — `v_member.roles ? 'founder'`). Mig 00019 added the
-- column with default `["member"]` and one-time backfilled
-- pre-existing admin rows to `["founder","member"]`. New rows inserted
-- by `create_group_with_admin` (mig 00079, line 119) write only
-- `(group_id, user_id, role='admin', active=true)` — the `roles`
-- jsonb stays at its default. The result: founders created since
-- BigBang cannot pass `can_modify_rules` / `has_permission` checks
-- that read jsonb (the legacy `is_group_admin` reads `role` text and
-- still works, masking the bug).
--
-- The DB test `can_modify_rules — founder + governance=founder → true`
-- (in supabase/functions/_tests/db/can_modify_rules.test.ts:42)
-- catches this: it expects the founder's call to return true and gets
-- false because the freshly-created founder lacks 'founder' in roles.
--
-- Changes
-- =======
-- 1. Recreate `create_group_with_admin` so the founder membership row
--    is inserted with `roles = '["founder","member"]'::jsonb`. Every
--    new group created after this migration has a consistent founder.
-- 2. One-time UPDATE for legacy admins whose `roles` is missing the
--    'founder' tag. Bounded to `role='admin' AND active`; the 4-row
--    audit above expects exactly 2 rows touched in prod.
--
-- Idempotent: `update` is filtered by the same predicate the bug
-- check used, so re-running is a no-op once rows are fixed.

-- =============================================================================
-- 1. Recreate create_group_with_admin with founder roles seed
-- =============================================================================

create or replace function public.create_group_with_admin(
  p_name                     text,
  p_description              text default null,
  p_currency                 text default 'MXN',
  p_timezone                 text default 'America/Mexico_City',
  p_base_template            text default null,
  p_cover_image_name         text default null,
  p_initial_event_vocabulary text default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g                       public.groups;
  uid                     uuid := auth.uid();
  template_config         jsonb;
  resolved_event_vocab    text;
  resolved_active_modules jsonb;
  resolved_governance     jsonb;
  resolved_settings       jsonb;
  resolved_category       text;
  resolved_initials       text;
  trimmed_name            text := trim(p_name);
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if trimmed_name is null or length(trimmed_name) = 0 then
    raise exception 'create_group_with_admin: p_name is required';
  end if;

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    select t.config into template_config
      from public.templates t
     where t.id = p_base_template
     limit 1;
  end if;

  resolved_event_vocab := coalesce(
    nullif(p_initial_event_vocabulary, ''),
    template_config #>> '{presentation,defaultEventLabel}',
    template_config #>> '{defaultSettings,eventVocabulary}',
    'evento'
  );

  resolved_active_modules := coalesce(
    template_config -> 'defaultModules',
    '[]'::jsonb
  );

  resolved_governance := coalesce(template_config -> 'defaultGovernance', '{}'::jsonb);

  resolved_settings := coalesce(template_config -> 'defaultSettings', '{}'::jsonb)
    || jsonb_build_object('eventVocabulary', resolved_event_vocab);

  resolved_category := coalesce(template_config ->> 'defaultCategory', 'socialRecurring');

  resolved_initials := upper(
    case
      when array_length(string_to_array(trimmed_name, ' '), 1) >= 2 then
        substring(trim(split_part(trimmed_name, ' ', 1)) from 1 for 1) ||
        substring(trim(split_part(trimmed_name, ' ', 2)) from 1 for 1)
      else
        substring(trimmed_name from 1 for 2)
    end
  );

  insert into public.groups (
    name, description, currency, timezone, base_template,
    cover_image_name, active_modules, governance, settings, category,
    initials, created_by
  ) values (
    trimmed_name, nullif(trim(coalesce(p_description, '')), ''),
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    p_base_template,
    p_cover_image_name,
    resolved_active_modules,
    resolved_governance,
    resolved_settings,
    resolved_category,
    resolved_initials,
    uid
  ) returning * into g;

  -- Founder membership. Tier 0.5 fix (2026-05-12): seed `roles` jsonb
  -- with `["founder","member"]` so jsonb-based permission helpers
  -- (can_modify_rules, has_permission) see the founder correctly.
  -- Legacy `role='admin'` text column kept for backwards compatibility
  -- with helpers that still read it (mig 00106 marked it DEPRECATED
  -- but didn't drop).
  insert into public.group_members (group_id, user_id, role, roles, active)
    values (g.id, uid, 'admin', '["founder","member"]'::jsonb, true);

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);
  end if;

  return g;
end;
$$;

revoke execute on function public.create_group_with_admin(
  text, text, text, text, text, text, text
) from public, anon;
grant  execute on function public.create_group_with_admin(
  text, text, text, text, text, text, text
) to authenticated;

comment on function public.create_group_with_admin(
  text, text, text, text, text, text, text
) is
  'Bare-group create. Tier 0.5 (2026-05-12): founder member now seeded with roles=["founder","member"] so jsonb permission helpers resolve correctly. Reads templates.config for active_modules / governance / category / event vocabulary.';

-- =============================================================================
-- 2. One-time backfill of legacy admins missing 'founder' in roles
-- =============================================================================

-- Rows with role='admin' but roles jsonb doesn't contain 'founder'.
-- 2026-05-12 prod audit: 2 rows. Idempotent — if re-run, no rows match.
update public.group_members
   set roles = case
                 when roles is null or jsonb_typeof(roles) <> 'array'
                   then '["founder","member"]'::jsonb
                 else roles || '["founder"]'::jsonb
               end
 where role = 'admin'
   and active = true
   and not coalesce(roles ? 'founder', false);
