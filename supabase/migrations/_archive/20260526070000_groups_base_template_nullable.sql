-- Allow groups to be created without a base template.
--
-- Founder doctrine (CLAUDE.md): "Template = preset inicial — solo arranca
-- el grupo, no es cárcel." A group MUST be able to start blank.
--
-- Two changes:
--   1. groups.base_template loses NOT NULL (and the legacy
--      'recurring_dinner' default that forced obsolete preset).
--   2. create_group_with_admin maps empty p_base_template → NULL via
--      nullif(trim(...), '') so the iOS CreateGroupSheet path (which
--      now passes "") yields a templateless group.
--
-- Backwards compat: existing rows keep their base_template values
-- (no UPDATE). Downstream consumers that read base_template must
-- handle null (audited: TemplateRegistry-based loaders already
-- treat unknown values as "no template", per Group.swift comment).

alter table public.groups
  alter column base_template drop not null,
  alter column base_template drop default;

comment on column public.groups.base_template is
  'Optional template id. NULL = group started blank (no preset). When set, references templates.id but no FK because templates can be deprecated without orphaning groups. Mig groups_base_template_nullable removed the recurring_dinner default + NOT NULL.';

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
  -- mig groups_base_template_nullable: empty/whitespace → NULL so a
  -- blank-started group leaves base_template unset instead of pinning
  -- the obsolete 'recurring_dinner' default.
  resolved_template       text := nullif(trim(coalesce(p_base_template, '')), '');
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if trimmed_name is null or length(trimmed_name) = 0 then
    raise exception 'create_group_with_admin: p_name is required';
  end if;

  if resolved_template is not null then
    select t.config into template_config
      from public.templates t
     where t.id = resolved_template
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
    resolved_template,
    p_cover_image_name,
    resolved_active_modules,
    resolved_governance,
    resolved_settings,
    resolved_category,
    resolved_initials,
    uid
  ) returning * into g;

  insert into public.group_members (group_id, user_id, roles, active)
    values (g.id, uid, '["founder","member"]'::jsonb, true);

  if resolved_template is not null then
    perform public.seed_template_roles(resolved_template, g.id);
  end if;

  perform public.seed_shared_pool_for_group(g.id, coalesce(p_currency, 'MXN'));

  return g;
end;
$function$;

comment on function public.create_group_with_admin(text, text, text, text, text, text, text) is
  'Creates a new group + admin member + (optional) template-role seeds + shared money pool. SECURITY DEFINER. p_base_template may be null/empty — the group starts blank, no preset rules, no preset vocabulary beyond "evento". Doctrine: "template = preset inicial, no es cárcel" (CLAUDE.md).';
