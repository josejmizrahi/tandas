-- Mig 00184: Governance base clean — wipe legacy rules + retire auto-seed.
-- Context: Beta 1 Rule Builder (mig 00181/00182) shipped 2026-05-15. Founder
-- decision 2026-05-15: existing groups are disposable test groups; start fresh
-- from base so every rule going forward carries a `rule_versions` snapshot
-- (compiled via publish_rule_version). Templates' defaultRules path was the
-- one source still bypassing the Builder — kill it.
--
-- This migration:
--   1. Drops the append-only atom guards on rule_versions + rule_evaluations
--      temporarily, wipes the data (rules + cascade-related), restores the
--      guards. One-time cleanup; subsequent operations remain append-only.
--   2. Rewrites `create_group_with_admin` to skip `seed_template_rules`
--      auto-call. Roles seed (`seed_template_roles`) still runs — different
--      concern. New groups start with zero rules. Admin uses Builder.

-- =============================================================================
-- 1. Wipe rule data — drop guards, delete, re-attach guards
-- =============================================================================

drop trigger if exists rule_evaluations_atom_guard_trg on public.rule_evaluations;
drop trigger if exists rule_versions_atom_guard_trg   on public.rule_versions;

delete from public.rule_evaluations;
delete from public.rule_conflicts;
delete from public.rule_versions;
delete from public.rules;

-- Re-attach the append-only guards (same definitions as mig 00181).
create trigger rule_evaluations_atom_guard_trg
  before update or delete on public.rule_evaluations
  for each row execute function public.rule_evaluations_atom_guard();

create trigger rule_versions_atom_guard_trg
  before update or delete on public.rule_versions
  for each row execute function public.rule_versions_atom_guard();

-- =============================================================================
-- 2. Rewrite create_group_with_admin — skip auto-seed of rules
-- =============================================================================

create or replace function public.create_group_with_admin(
  p_name text,
  p_description text default null,
  p_currency text default 'MXN',
  p_timezone text default 'America/Mexico_City',
  p_base_template text default null,
  p_cover_image_name text default null,
  p_initial_event_vocabulary text default null
)
returns public.groups
language plpgsql
security definer
set search_path = 'public'
as $function$
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

  insert into public.group_members (group_id, user_id, role, roles, active)
    values (g.id, uid, 'admin', '["founder","member"]'::jsonb, true);

  -- Per Plans/Active/Governance.md doctrine (Beta 1 Rule Builder, 2026-05-15):
  -- groups no longer auto-seed rules. Admin uses the Builder explicitly so
  -- every rule lands with a `rule_versions` snapshot from the start. Roles
  -- continue to seed automatically — different layer of governance.
  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);
  end if;

  return g;
end;
$function$;

comment on function public.create_group_with_admin(text, text, text, text, text, text, text) is
  'Creates a group + founding admin membership + seeds template roles. Per mig 00184 (2026-05-15): NO LONGER auto-seeds rules — groups start with zero rules, admin adds them explicitly via the Beta 1 Rule Builder (publish_rule_version RPC, mig 00182). Roles seed remains because roles are governance structure, not behavior rules.';
