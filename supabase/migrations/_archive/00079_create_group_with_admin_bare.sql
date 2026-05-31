-- 00079 — Rewrite create_group_with_admin for bare-group schema (post BigBang).
--
-- After mig 00078 dropped groups.event_label / frequency_* / fines_enabled
-- etc., the existing create_group_with_admin RPC tried to INSERT into those
-- columns and failed at runtime. iOS createInitial / create paths also send
-- new params (p_description, p_initial_event_vocabulary) the old signature
-- doesn't accept. Both broke onboarding.
--
-- This migration:
--   1. Drops both legacy overloads (the 6-arg one from 00051 with
--      p_event_label/p_group_type, and the 12-arg one from mig 00011).
--   2. Recreates the function with the new bare-group signature matching
--      what iOS now sends.
--   3. Stores eventVocabulary in `settings` jsonb (no flat column).
--   4. Resolves active_modules / governance / category from
--      `templates.config` when a template is provided; defaults to empty
--      jsonb arrays for bare groups (no preset).
--
-- Param semantics:
--   - p_name                       required
--   - p_description                optional, free text
--   - p_currency                   default MXN
--   - p_timezone                   default America/Mexico_City
--   - p_base_template              optional. NULL = bare group, no preset.
--   - p_cover_image_name           optional
--   - p_initial_event_vocabulary   optional. Goes to settings.eventVocabulary.
--                                  Falls back to template default or 'evento'.

drop function if exists public.create_group_with_admin(text, text, text, text, text, text);
drop function if exists public.create_group_with_admin(text, text, text, text, text, text, text);
drop function if exists public.create_group_with_admin(text, text, text, text, text, integer, time, text, numeric, numeric, boolean, text);

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

  -- Optional template lookup (bare groups skip this).
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

  -- Founder membership row.
  insert into public.group_members (group_id, user_id, role, active)
    values (g.id, uid, 'admin', true);

  -- Seed template-defined roles if a template is set.
  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);
  end if;

  -- Re-fetch to capture trigger updates (e.g. trigger-derived initials).
  select * into g from public.groups where id = g.id;

  return g;
end;
$$;

revoke execute on function public.create_group_with_admin(
  text, text, text, text, text, text, text
) from public, anon;
grant execute on function public.create_group_with_admin(
  text, text, text, text, text, text, text
) to authenticated;

comment on function public.create_group_with_admin(
  text, text, text, text, text, text, text
) is 'Bare-group creation post BigBang (mig 00078). Resolves modules/governance/settings from templates.config when p_base_template is set; defaults to empty jsonb for bare groups. eventVocabulary lives in settings jsonb (no flat column).';
