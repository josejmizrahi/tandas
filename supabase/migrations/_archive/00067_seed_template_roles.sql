-- 00067 — seed_template_roles RPC + create_group_with_admin wiring.
--
-- Audit Q3 (post-Phase-2-Slice-1 review): templates.config.defaultRoles
-- was declared in mig 00066 (shared_resource template) but had zero
-- consumers. Server's create_group_with_admin didn't copy it; iOS
-- TemplateConfig didn't decode it. seat_owner / co_owner / guest_holder
-- were inert data.
--
-- This migration ships the server-side seam:
--   1. seed_template_roles(p_template_id, p_group_id) — idempotent
--      RPC that copies templates.config.defaultRoles → groups.roles.
--      Mirror of seed_template_rules (mig 00062): fail open if
--      template has no defaultRoles, no-op if group already has
--      non-system roles seeded.
--   2. create_group_with_admin — extends the existing function
--      (00051) to invoke seed_template_roles after group creation.
--      All groups created via this RPC get their template's
--      defaultRoles applied atomically with insert.

-- =========================================================
-- 1. seed_template_roles RPC
-- =========================================================
create or replace function public.seed_template_roles(
  p_template_id text,
  p_group_id    uuid
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_default_roles jsonb;
  v_current_roles jsonb;
  v_has_custom_role boolean;
  g public.groups;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template roles';
  end if;

  select config -> 'defaultRoles'
    into v_default_roles
    from public.templates
   where id = p_template_id;

  -- Template has no defaultRoles → no-op, return current group state.
  if v_default_roles is null or jsonb_typeof(v_default_roles) <> 'object' then
    select * into g from public.groups where id = p_group_id;
    return g;
  end if;

  -- Idempotency: skip if any non-system role already present (group
  -- was already seeded or founder added custom roles via Phase 5
  -- assign_role).
  select roles into v_current_roles from public.groups where id = p_group_id;
  select exists (
    select 1
    from jsonb_each(coalesce(v_current_roles, '{}'::jsonb)) r(key, value)
    where key not in ('founder', 'member')
  ) into v_has_custom_role;

  if v_has_custom_role then
    select * into g from public.groups where id = p_group_id;
    return g;
  end if;

  -- Apply: replace groups.roles with template defaults. Template's
  -- founder/member entries override the column-default seed from
  -- mig 00063 (so a template can extend system roles with its own
  -- permissions, e.g. shared_resource adds assignSlot to founder).
  update public.groups
     set roles = v_default_roles
   where id = p_group_id
   returning * into g;

  return g;
end;
$$;

revoke execute on function public.seed_template_roles(text, uuid) from public, anon;
grant  execute on function public.seed_template_roles(text, uuid) to authenticated;

comment on function public.seed_template_roles(text, uuid) is
  'Idempotent: applies templates.config.defaultRoles to groups.roles. Skips if group already has any non-system role (founder/member kept). No-op if template has no defaultRoles. Phase 2 closes Q3 audit gap from Slice 1 review.';

-- =========================================================
-- 2. create_group_with_admin — invoke seed_template_roles
-- =========================================================
-- Replays the body from mig 00051 with one addition: after the
-- INSERT into groups + group_members, call seed_template_roles so
-- any group created via this RPC inherits its template's role
-- catalog atomically.

create or replace function public.create_group_with_admin(
  p_name text,
  p_event_label text default null,
  p_currency text default 'MXN',
  p_timezone text default 'America/Mexico_City',
  p_base_template text default 'recurring_dinner',
  p_cover_image_name text default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  uid uuid := auth.uid();
  resolved_template text := coalesce(nullif(p_base_template, ''), 'recurring_dinner');
  template_config jsonb;
  resolved_event_label text;
  resolved_active_modules jsonb;
  resolved_governance jsonb;
  resolved_settings jsonb;
  resolved_category text;
  resolved_initials text;
begin
  if uid is null then raise exception 'not authenticated'; end if;

  select t.config
  into template_config
  from public.templates t
  where t.id = resolved_template
  limit 1;

  resolved_event_label := coalesce(
    nullif(p_event_label, ''),
    template_config #>> '{presentation,defaultEventLabel}',
    template_config #>> '{defaultSettings,eventVocabulary}',
    'evento'
  );

  resolved_active_modules := coalesce(
    template_config -> 'defaultModules',
    case
      when resolved_template = 'recurring_dinner' then
        '["basic_fines","rotating_host","rsvp","check_in","appeal_voting"]'::jsonb
      else
        '[]'::jsonb
    end
  );

  resolved_governance := coalesce(template_config -> 'defaultGovernance', '{}'::jsonb);
  resolved_settings := coalesce(template_config -> 'defaultSettings', '{}'::jsonb)
    || jsonb_build_object('eventVocabulary', resolved_event_label);
  resolved_category := coalesce(template_config ->> 'defaultCategory', 'socialRecurring');

  resolved_initials := upper(
    case
      when array_length(string_to_array(trim(p_name), ' '), 1) >= 2 then
        substring(trim(split_part(p_name, ' ', 1)) from 1 for 1) ||
        substring(trim(split_part(p_name, ' ', 2)) from 1 for 1)
      else
        substring(trim(p_name) from 1 for 2)
    end
  );

  insert into public.groups (
    name,
    event_label,
    currency,
    timezone,
    base_template,
    active_modules,
    governance,
    settings,
    category,
    initials,
    cover_image_name,
    created_by
  ) values (
    p_name,
    resolved_event_label,
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    resolved_template,
    resolved_active_modules,
    resolved_governance,
    resolved_settings,
    resolved_category,
    resolved_initials,
    p_cover_image_name,
    uid
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, active)
    values (g.id, uid, 'admin', true);

  -- Q3 fix (Phase 2 Slice 1 audit): apply template's defaultRoles to
  -- this group so custom roles (seat_owner / co_owner / etc.) are
  -- available immediately. seed_template_roles is idempotent — safe
  -- on re-call.
  perform public.seed_template_roles(resolved_template, g.id);

  -- Reload to capture the post-seed roles state.
  select * into g from public.groups where id = g.id;

  return g;
end;
$$;
