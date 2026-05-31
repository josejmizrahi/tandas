-- 00042 — Create groups from base_template, keep group_type as legacy input.
--
-- Audit §5.3 item 7c / Plans/Active/GroupTypeRemoval.md.
-- Swift no longer carries a GroupType enum. New clients call
-- create_group_with_admin with p_base_template. Old clients may still send
-- p_group_type during the cohabitation window; this function accepts both
-- and writes the legacy column from the resolved template id until the
-- follow-up DROP migration removes groups.group_type.

alter table public.groups
  alter column group_type drop not null;

comment on column public.groups.group_type is
  'DEPRECATED — use groups.base_template. Kept temporarily for old clients during GroupType removal cohabitation.';

drop function if exists public.create_group_with_admin(text, text, text, text, text, text);

create or replace function public.create_group_with_admin(
  p_name text,
  p_event_label text default null,
  p_currency text default 'MXN',
  p_timezone text default 'America/Mexico_City',
  p_base_template text default 'recurring_dinner',
  p_cover_image_name text default null,
  p_group_type text default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  uid uuid := auth.uid();
  resolved_template text := coalesce(nullif(p_base_template, ''), nullif(p_group_type, ''), 'recurring_dinner');
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
    group_type,
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

  return g;
end;
$$;

revoke execute on function public.create_group_with_admin(text, text, text, text, text, text, text) from public, anon;
grant  execute on function public.create_group_with_admin(text, text, text, text, text, text, text) to authenticated;
