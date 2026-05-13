-- 00134 — Tier 1.7 unblocker: create_group_with_admin auto-seeds the
-- template's defaultRules alongside the template's defaultRoles.
--
-- Background
-- ==========
-- 00128 made `create_group_with_admin` call `seed_template_roles`
-- automatically when a base template is provided, so a fresh group
-- lands fully role-configured. But it skipped `seed_template_rules`
-- — that one stayed an explicit second hop the caller had to make.
--
-- Real consequence (palcoSharedResource.test.ts quarantine):
--   group = await seedGroup({ baseTemplate: "shared_resource" });
--   const r = await admin.from("rules")
--     .eq("slug", "shared_no_show").single();   // → null
--
-- The `shared_resource` template's config.defaultRules array contains
-- `shared_no_show` + `shared_swap_warning` (mig 00066). But because
-- `create_group_with_admin` doesn't trigger the rule seeder, the rules
-- never make it into `public.rules`. The downstream chain
-- (slotExpired → rule fires → fine proposed) has nothing to evaluate.
--
-- iOS today calls `seed_template_rules` separately in the wizard flow
-- (LiveGroupsRepository / S1 founder welcome flow), so production
-- groups created via the iOS path have rules. The gap surfaces when
-- a server-side caller (e2e tests, future SDKs, admin tools) makes
-- only the canonical create_group_with_admin call.
--
-- Fix
-- ===
-- Wrap the rule seed in the same shape as the roles seed:
--   1. Look at templates.config -> 'defaultRules'.
--   2. If it's a non-empty array, call seed_template_rules.
--   3. Skip otherwise (covers `custom` / `rotating_savings` templates
--      that intentionally have no defaults).
--
-- Idempotency: seed_template_rules has its own re-seed guard
-- ("any existing platform-shape rule" → no-op). Groups already seeded
-- via the iOS hop see this as a no-op on the second pass.
--
-- Permissions: seed_template_rules requires `is_group_admin(group_id, uid)`.
-- The founder membership row is inserted with role='admin' right
-- before this call, so the check passes for the same `uid` running
-- the SECURITY DEFINER body.
--
-- No prod backfill: groups created before this migration that lack
-- defaultRules (e.g. dormant shared_resource testing groups) can
-- re-run `seed_template_rules` manually if needed. The 2026-05-12
-- Tier 0.5 audit had no such case in prod for shared_resource since
-- no real shared_resource groups exist yet.

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
  v_default_rules         jsonb;
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

  -- Founder membership — Tier 0.5 (00128): roles jsonb seeded
  -- so jsonb-based permission helpers (can_modify_rules,
  -- has_permission) see the founder correctly.
  insert into public.group_members (group_id, user_id, role, roles, active)
    values (g.id, uid, 'admin', '["founder","member"]'::jsonb, true);

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);

    -- Tier 1.7 (00134): also seed defaultRules when the template
    -- declares them. Skips templates that intentionally ship no rules
    -- (custom, rotating_savings). seed_template_rules is idempotent
    -- so a separate iOS-side call to seed_template_rules from the
    -- legacy wizard path becomes a no-op on the second pass.
    v_default_rules := template_config -> 'defaultRules';
    if v_default_rules is not null
       and jsonb_typeof(v_default_rules) = 'array'
       and jsonb_array_length(v_default_rules) > 0 then
      perform public.seed_template_rules(p_base_template, g.id);
    end if;
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
  'Bare-group create. Tier 1.7 (00134): also calls seed_template_rules when the template has a non-empty defaultRules array, so server-side callers (e2e tests, future SDKs) land in the same fully-seeded state as iOS wizard groups. Tier 0.5 (00128): founder member seeded with roles=["founder","member"] for jsonb permission helpers.';
