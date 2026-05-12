-- 00075 rollback — Restore seed_template_rules from mig 00062.
--
-- After rollback, seed_template_rules will bulk-insert all
-- `templates.config.defaultRules` regardless of active_modules and
-- WITHOUT module_key annotation. Use only if rolling back the whole
-- A-phase rule refactor.

drop function if exists public.seed_template_rules_legacy(text, uuid);

create or replace function public.seed_template_rules(
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

revoke execute on function public.seed_template_rules(text, uuid) from public, anon;
grant  execute on function public.seed_template_rules(text, uuid) to authenticated;
