-- Fix create_group_with_admin: drop the dead `role` column from INSERT.
--
-- Why
-- ===
-- Mig 00303 (V24.2, 2026-05-17) dropped `group_members.role` (text).
-- Mig 20260521151500 (SharedMoney Phase 1, 2026-05-21) redefined
-- `create_group_with_admin` to seed the shared pool — but copied the
-- old INSERT body verbatim, including the now-dead `role` column.
--
-- Result: every call to create_group_with_admin since 2026-05-21 has
-- failed with `column "role" of relation "group_members" does not
-- exist` (SQLSTATE 42703). Founders cannot create new groups.
--
-- Fix
-- ===
-- Re-define the function identical to the mig 00357 body EXCEPT the
-- INSERT into group_members now uses only the surviving `roles` jsonb
-- column. Primary role is already derived from roles[] everywhere
-- downstream (mig 00303 covered get_member_summary, export_my_data;
-- iOS LiveGroupsRepository.get derives myRole from rawRoles).

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

  -- mig 00303 dropped group_members.role. roles[] jsonb is the only
  -- surviving role storage. Primary role is derived from roles[].
  insert into public.group_members (group_id, user_id, roles, active)
    values (g.id, uid, '["founder","member"]'::jsonb, true);

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);
  end if;

  -- SharedMoney Phase 1 (mig 00357): seed the canonical shared pool.
  -- Idempotent; no fundCreated atom; stamps is_shared_pool / seeded_by_system.
  perform public.seed_shared_pool_for_group(g.id, coalesce(p_currency, 'MXN'));

  return g;
end;
$function$;

comment on function public.create_group_with_admin(text, text, text, text, text, text, text) is
  'Creates a new group + admin member + template-role seeds + (mig 00357) the canonical shared money pool. SECURITY DEFINER. Every new group is born with exactly one is_shared_pool=true fund row. Role stored only in roles[] jsonb (mig 00303 dropped the text column).';
