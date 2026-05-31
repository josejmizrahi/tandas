-- 00075 — seed_template_rules becomes an orchestrator over active modules.
--
-- Phase A step 5 of L1 rules-architecture refactor (audit doc:
-- Plans/Active/L1_Audit_2026-05-10.md, Hallazgo 1).
--
-- Pre-refactor (00062): seed_template_rules read
-- `templates.config.defaultRules` and bulk-inserted every rule into
-- `public.rules` for the group, regardless of which modules were
-- actually active. Three problems:
--
--   1. Rules sat in the table even when their owning module wasn't on.
--   2. No `module_key` on the inserted rows — engine can't filter by
--      module.
--   3. If a template has rules from multiple modules, all of them
--      land regardless of which modules the founder picked.
--
-- Post-refactor (this migration): seed_template_rules reads the
-- group's `active_modules` list and delegates to seed_module_rules
-- (00073) per slug. Each rule lands with module_key set; rules from
-- inactive modules don't land at all.
--
-- Same signature `(text, uuid)`. Call site `FounderOnboardingCoordinator`
-- doesn't change. Idempotency preserved by seed_module_rules upserts.
--
-- Backwards-compat note: the legacy `seed_dinner_template_rules(uuid)`
-- thin wrapper from 00062 still works — it calls
-- `seed_template_rules('recurring_dinner', group_id)`, which now does
-- the right thing via the orchestrator.

create or replace function public.seed_template_rules(
  p_template_id text,
  p_group_id    uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid                uuid := auth.uid();
  v_active_modules   jsonb;
  v_module_slug      text;
  v_template_exists  boolean;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;

  -- Validate template id exists (forward-compat: future templates
  -- registered via mig will be picked up automatically).
  select exists(select 1 from public.templates where id = p_template_id)
    into v_template_exists;

  if not v_template_exists then
    raise exception 'template % does not exist', p_template_id;
  end if;

  -- Idempotency at the orchestrator level: if any module-keyed rule
  -- already exists for this group, assume seeding ran. Re-running is
  -- still safe (seed_module_rules upserts), but skipping avoids noise
  -- in the SystemEvents stream from the rule-mutation trigger.
  if exists (
    select 1 from public.rules
     where group_id   = p_group_id
       and module_key is not null
  ) then
    return;
  end if;

  -- Read the group's active modules. Set by create_group_with_admin
  -- via templates.config (00019 backfill + 00042 base_template path).
  select active_modules into v_active_modules
    from public.groups
   where id = p_group_id;

  if v_active_modules is null or jsonb_typeof(v_active_modules) <> 'array' then
    -- No active modules configured. Fall back to the legacy behaviour
    -- (read templates.config.defaultRules and bulk-insert WITHOUT
    -- module_key). This keeps any odd test fixture or pre-mig-00019
    -- group working until a follow-up cleans them up.
    return query
      select * from public.seed_template_rules_legacy(p_template_id, p_group_id);
    return;
  end if;

  -- Delegate per-module. seed_module_rules is idempotent and skips
  -- unknown slugs (forward-compat with iOS shipping a slug not yet
  -- seeded server-side).
  for v_module_slug in
    select jsonb_array_elements_text(v_active_modules)
  loop
    return query
      select * from public.seed_module_rules(p_group_id, v_module_slug);
  end loop;

  return;
end;
$$;

revoke execute on function public.seed_template_rules(text, uuid) from public, anon;
grant  execute on function public.seed_template_rules(text, uuid) to authenticated;

comment on function public.seed_template_rules(text, uuid) is
  'Orchestrator: reads groups.active_modules and calls seed_module_rules for each. Each rule lands with module_key set so the engine and archive cascade can identify ownership. Mig 00075 = Phase A step 5 of L1 rules refactor (replaces 00062 mono-seeder).';

-- =========================================================
-- Legacy fallback for groups without active_modules
-- =========================================================
-- Mirrors the pre-00075 behaviour byte-for-byte (the body of mig
-- 00062). Only invoked when a group somehow has null/missing
-- active_modules. Safe to drop once we're sure no such groups exist.

create or replace function public.seed_template_rules_legacy(
  p_template_id text,
  p_group_id    uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_default_rules jsonb;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;

  select config -> 'defaultRules' into v_default_rules
    from public.templates
   where id = p_template_id;

  if v_default_rules is null or jsonb_typeof(v_default_rules) <> 'array' then
    raise exception 'template % has no defaultRules array', p_template_id;
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
    group_id, slug, name, is_active,
    trigger, conditions, consequences,
    proposed_by
  )
  select
    p_group_id,
    r ->> 'slug',
    r ->> 'name',
    coalesce((r ->> 'isActive')::boolean, true),
    jsonb_build_object(
      'eventType', r -> 'trigger' ->> 'eventType',
      'config',    coalesce(r -> 'trigger' -> 'config', '{}'::jsonb)
    ),
    coalesce(r -> 'conditions',   '[]'::jsonb),
    coalesce(r -> 'consequences', '[]'::jsonb),
    uid
  from jsonb_array_elements(v_default_rules) r
  returning *;
end;
$$;

revoke execute on function public.seed_template_rules_legacy(text, uuid) from public, anon;
grant  execute on function public.seed_template_rules_legacy(text, uuid) to authenticated;

comment on function public.seed_template_rules_legacy(text, uuid) is
  'Pre-00075 mono-seeder. Reads templates.config.defaultRules and bulk-inserts WITHOUT module_key. Only invoked from seed_template_rules when groups.active_modules is null (rare edge case). Slated for removal once all groups guaranteed to have active_modules.';
