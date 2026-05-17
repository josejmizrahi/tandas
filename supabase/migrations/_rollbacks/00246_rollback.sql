-- Rollback for 00246_publish_rule_composition_with_slug.sql.
--
-- Restores the 7-arg signature from mig 00245 (no p_slug, no slug in
-- result). Drops the slugify_camel helper (only consumed by the v2 RPC).

drop function if exists public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text);
drop function if exists public.slugify_camel(text);

create or replace function public.publish_rule_composition(
  p_group_id      uuid,
  p_name          text,
  p_scope         jsonb,
  p_trigger       jsonb,
  p_conditions    jsonb default '[]'::jsonb,
  p_consequences  jsonb default '[]'::jsonb,
  p_change_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid              uuid := auth.uid();
  v_scope_type       text;
  v_scope_id         uuid;
  v_resource_type    text;
  v_trigger_id       text;
  v_trigger_config   jsonb;
  v_trigger_valid_scopes        text[];
  v_trigger_valid_resource_types text[];
  v_cond             jsonb;
  v_cond_id          text;
  v_cons             jsonb;
  v_cons_id          text;
  v_compiled         jsonb;
  v_rule_id          uuid;
  v_rule_version_id  uuid;
  v_resource_id      uuid;
  v_series_id        uuid;
  v_conflicts        jsonb := '[]'::jsonb;
  v_against          record;
  v_clean_conds      jsonb;
  v_clean_cons       jsonb;
begin
  if v_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if not public.has_permission(p_group_id, v_uid, 'modifyRules') then
    raise exception 'modifyRules permission required' using errcode = '42501';
  end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'rule name must be at least 2 characters' using errcode = '22023'; end if;
  if p_trigger is null or jsonb_typeof(p_trigger) <> 'object' then raise exception 'trigger required' using errcode = '22023'; end if;
  if jsonb_typeof(p_consequences) <> 'array' or jsonb_array_length(p_consequences) = 0 then raise exception 'at least one consequence required' using errcode = '22023'; end if;
  v_scope_type := coalesce(p_scope->>'type', 'group');
  if v_scope_type not in ('resource','series','group') then raise exception 'unsupported scope.type=%', v_scope_type using errcode = '22023'; end if;
  if v_scope_type = 'resource' then
    v_scope_id := nullif(p_scope->>'id','')::uuid;
    select resource_type into v_resource_type from public.resources where id = v_scope_id;
    v_resource_id := v_scope_id;
  elsif v_scope_type = 'series' then
    v_scope_id := nullif(p_scope->>'id','')::uuid;
    select r.resource_type into v_resource_type from public.resources r where r.series_id = v_scope_id limit 1;
    v_series_id := v_scope_id;
  end if;
  v_trigger_id := p_trigger->>'shape_id';
  v_trigger_config := coalesce(p_trigger->'config', '{}'::jsonb);
  select valid_scopes, valid_resource_types into v_trigger_valid_scopes, v_trigger_valid_resource_types
    from public.rule_shapes where id = v_trigger_id and kind = 'trigger';
  v_clean_conds := '[]'::jsonb;
  for v_cond in select * from jsonb_array_elements(coalesce(p_conditions, '[]'::jsonb)) loop
    v_clean_conds := v_clean_conds || jsonb_build_array(jsonb_build_object('type', v_cond->>'shape_id', 'config', coalesce(v_cond->'config', '{}'::jsonb)));
  end loop;
  v_clean_cons := '[]'::jsonb;
  for v_cons in select * from jsonb_array_elements(p_consequences) loop
    v_clean_cons := v_clean_cons || jsonb_build_array(jsonb_build_object('type', v_cons->>'shape_id', 'config', coalesce(v_cons->'config', '{}'::jsonb)));
  end loop;
  v_compiled := jsonb_build_object(
    'trigger', jsonb_build_object('eventType', v_trigger_id, 'config', v_trigger_config),
    'conditions', v_clean_conds, 'consequences', v_clean_cons,
    'exceptions', '[]'::jsonb, 'scope', p_scope,
    'target', jsonb_build_object('type','ref','value','$trigger.actor'),
    'shape_ids', jsonb_build_object('trigger', v_trigger_id,
      'conditions', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_conds) c),
      'consequences', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_cons) c))
  );
  insert into public.rules (group_id, name, trigger, conditions, consequences, is_active, slug, resource_id, series_id, membership_id, module_key, proposed_by, created_at, updated_at)
  values (p_group_id, trim(p_name), v_compiled->'trigger', v_compiled->'conditions', v_compiled->'consequences', true, null, v_resource_id, v_series_id, null, null, v_uid, now(), now())
  returning id into v_rule_id;
  insert into public.rule_versions (rule_id, version, template_id, shape_params, compiled, status, effective_from, effective_until, previous_version_id, created_by, change_reason)
  values (v_rule_id, 1, null, '{}'::jsonb, v_compiled, 'active', now(), null, null, v_uid, p_change_reason)
  returning id into v_rule_version_id;
  return jsonb_build_object('rule_id', v_rule_id, 'rule_version_id', v_rule_version_id, 'version', 1, 'conflicts', v_conflicts);
end;
$$;

revoke execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text) from public, anon;
grant  execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text) to authenticated, service_role;
