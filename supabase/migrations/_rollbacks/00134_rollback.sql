-- Rollback 00134 — restore the 00128 body of create_group_with_admin
-- (founder roles seed but no automatic rule seed). Existing rules
-- inserted by the auto-seed path stay — they're real group state.

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

  insert into public.group_members (group_id, user_id, role, roles, active)
    values (g.id, uid, 'admin', '["founder","member"]'::jsonb, true);

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);
  end if;

  return g;
end;
$$;

comment on function public.create_group_with_admin(
  text, text, text, text, text, text, text
) is
  'Bare-group create. Tier 0.5 (2026-05-12): founder member now seeded with roles=["founder","member"] so jsonb permission helpers resolve correctly. Reads templates.config for active_modules / governance / category / event vocabulary.';
