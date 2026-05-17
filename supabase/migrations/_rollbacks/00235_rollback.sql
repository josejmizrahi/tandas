-- Rollback for 00235_rule_rpcs_gated_on_has_permission.sql
--
-- Restores prior bodies: publish_rule_version from mig 00182 +
-- seed_template_rules from mig 00075. Both gate on is_group_admin.

create or replace function public.publish_rule_version(
  p_group_id     uuid,
  p_template_id  text,
  p_shape_params jsonb default '{}'::jsonb,
  p_scope        jsonb default '{"type": "group"}'::jsonb,
  p_title        text default null,
  p_change_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid             uuid := auth.uid();
  v_template        public.rule_templates;
  v_scope_type      text;
  v_resource_id     uuid;
  v_series_id       uuid;
  v_trigger_id      text;
  v_condition_ids   text[];
  v_consequence_ids text[];
  v_params          jsonb;
  v_compiled        jsonb;
  v_rule_id         uuid;
  v_rule_version_id uuid;
  v_title           text;
  v_conflicts       jsonb := '[]'::jsonb;
  v_against         record;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_group_admin(p_group_id, v_uid) then
    raise exception 'admin only' using errcode = '42501';
  end if;

  select * into v_template from public.rule_templates where id = p_template_id;
  if not found then
    raise exception 'rule_template % not found', p_template_id using errcode = '22023';
  end if;
  if v_template.status <> 'active' then
    raise exception 'rule_template % is %', p_template_id, v_template.status using errcode = '22023';
  end if;

  v_scope_type := coalesce(p_scope->>'type', 'group');
  if v_scope_type = 'resource' then
    v_resource_id := (p_scope->>'id')::uuid;
    if v_resource_id is null then
      raise exception 'scope.id required for type=resource' using errcode = '22023';
    end if;
  elsif v_scope_type = 'series' then
    v_series_id := (p_scope->>'id')::uuid;
    if v_series_id is null then
      raise exception 'scope.id required for type=series' using errcode = '22023';
    end if;
  elsif v_scope_type = 'group' then
    -- no-op
  else
    raise exception 'unsupported scope.type=%', v_scope_type using errcode = '22023';
  end if;

  v_trigger_id      := v_template.composition->>'trigger_shape_id';
  v_condition_ids   := coalesce(array(select jsonb_array_elements_text(v_template.composition->'condition_shape_ids')),   '{}'::text[]);
  v_consequence_ids := coalesce(array(select jsonb_array_elements_text(v_template.composition->'consequence_shape_ids')), '{}'::text[]);

  if v_trigger_id is null then
    raise exception 'template % missing composition.trigger_shape_id', p_template_id using errcode = '22023';
  end if;
  if not exists (select 1 from public.rule_shapes where id = v_trigger_id and kind = 'trigger') then
    raise exception 'trigger shape % not found (or wrong kind)', v_trigger_id using errcode = '22023';
  end if;
  if exists (
    select 1
    from unnest(v_condition_ids) as cid
    where not exists (select 1 from public.rule_shapes where id = cid and kind = 'condition')
  ) then
    raise exception 'one or more condition shapes invalid: %', v_condition_ids using errcode = '22023';
  end if;
  if exists (
    select 1
    from unnest(v_consequence_ids) as cid
    where not exists (select 1 from public.rule_shapes where id = cid and kind = 'consequence')
  ) then
    raise exception 'one or more consequence shapes invalid: %', v_consequence_ids using errcode = '22023';
  end if;

  v_params := coalesce(v_template.default_params, '{}'::jsonb) || coalesce(p_shape_params, '{}'::jsonb);

  v_compiled := jsonb_build_object(
    'trigger',      jsonb_build_object('eventType', v_trigger_id, 'config', v_params),
    'conditions',   (
      select coalesce(jsonb_agg(jsonb_build_object('type', cid, 'config', v_params)), '[]'::jsonb)
      from unnest(v_condition_ids) as cid
    ),
    'consequences', (
      select coalesce(jsonb_agg(jsonb_build_object('type', cid, 'config', v_params)), '[]'::jsonb)
      from unnest(v_consequence_ids) as cid
    ),
    'exceptions',   '[]'::jsonb,
    'scope',        p_scope,
    'target',       jsonb_build_object('type', 'ref', 'value', '$trigger.actor'),
    'shape_ids',    jsonb_build_object(
                      'trigger',      v_trigger_id,
                      'conditions',   to_jsonb(v_condition_ids),
                      'consequences', to_jsonb(v_consequence_ids)
                    )
  );

  for v_against in (
    select rv.id as rv_id, r2.name as r_title
    from public.rule_versions rv
    join public.rules r2 on r2.id = rv.rule_id
    where r2.group_id = p_group_id
      and rv.status = 'active'
      and rv.compiled->'trigger'->>'eventType' = v_trigger_id
      and coalesce(rv.compiled->'scope', '{}'::jsonb) = p_scope
  ) loop
    v_conflicts := v_conflicts || jsonb_build_object(
      'type',     'same_scope_overlapping',
      'severity', 'warning',
      'against_rule_version_id', v_against.rv_id,
      'against_rule_title',      v_against.r_title
    );
  end loop;

  v_title := coalesce(nullif(trim(p_title), ''), v_template.display_name_es);
  insert into public.rules (
    group_id, name, trigger, conditions, consequences,
    is_active, slug,
    resource_id, series_id, membership_id, module_key,
    proposed_by, created_at, updated_at
  )
  values (
    p_group_id, v_title,
    v_compiled->'trigger', v_compiled->'conditions', v_compiled->'consequences',
    true, p_template_id,
    v_resource_id, v_series_id, null, null,
    v_uid, now(), now()
  )
  returning id into v_rule_id;

  insert into public.rule_versions (
    rule_id, version, template_id, shape_params, compiled,
    status, effective_from, effective_until,
    previous_version_id, created_by, change_reason
  )
  values (
    v_rule_id, 1, p_template_id, p_shape_params, v_compiled,
    'active', now(), null,
    null, v_uid, p_change_reason
  )
  returning id into v_rule_version_id;

  if jsonb_array_length(v_conflicts) > 0 then
    insert into public.rule_conflicts (group_id, rule_a_version_id, rule_b_version_id, conflict_type, severity)
    select p_group_id, v_rule_version_id, (c->>'against_rule_version_id')::uuid, c->>'type', c->>'severity'
    from jsonb_array_elements(v_conflicts) as c;
  end if;

  return jsonb_build_object(
    'rule_id',         v_rule_id,
    'rule_version_id', v_rule_version_id,
    'version',         1,
    'conflicts',       v_conflicts
  );
end;
$$;

create or replace function public.seed_template_rules(
  p_template_id text,
  p_group_id    uuid
)
returns setof public.rules
language plpgsql
security definer
set search_path = public
as $$
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

  select exists(select 1 from public.templates where id = p_template_id)
    into v_template_exists;

  if not v_template_exists then
    raise exception 'template % does not exist', p_template_id;
  end if;

  if exists (
    select 1 from public.rules
     where group_id   = p_group_id
       and module_key is not null
  ) then
    return;
  end if;

  select active_modules into v_active_modules
    from public.groups
   where id = p_group_id;

  if v_active_modules is null or jsonb_typeof(v_active_modules) <> 'array' then
    return query
      select * from public.seed_template_rules_legacy(p_template_id, p_group_id);
    return;
  end if;

  for v_module_slug in
    select jsonb_array_elements_text(v_active_modules)
  loop
    return query
      select * from public.seed_module_rules(p_group_id, v_module_slug);
  end loop;

  return;
end;
$$;
