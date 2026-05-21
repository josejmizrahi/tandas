-- Rollback for 20260521151500_shared_pool_marker_and_seed.sql.
-- Restores create_group_with_admin to the pre-mig-00357 body (no seed
-- call), drops both seed helpers, then drops the partial unique index.
--
-- Already-seeded shared pool rows on new groups STAY. They behave as
-- inert fund rows post-rollback — nothing reads metadata.is_shared_pool
-- after rollback, but the data is harmless and can be deleted
-- manually if needed. NOT cleaned up automatically to preserve data
-- safety.

-- 1. Restore create_group_with_admin to pre-00357 body.
create or replace function public.create_group_with_admin(
  p_name                       text,
  p_description                text default null,
  p_currency                   text default 'MXN',
  p_timezone                   text default 'America/Mexico_City',
  p_base_template              text default null,
  p_cover_image_name           text default null,
  p_initial_event_vocabulary   text default null
)
returns public.groups
language plpgsql
security definer
set search_path to 'public'
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

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);
  end if;

  return g;
end;
$function$;

-- 2. Drop the two helper RPCs.
drop function if exists public.seed_shared_pool_for_existing_group(uuid);
drop function if exists public.seed_shared_pool_for_group(uuid, text);

-- 3. Drop the partial unique index.
drop index if exists public.resources_one_shared_pool_per_group;
