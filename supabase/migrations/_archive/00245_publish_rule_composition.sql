-- 00245 — publish_rule_composition: server-side free composition endpoint.
--
-- Companion to publish_rule_version (mig 00182): instead of taking a
-- pre-baked rule_templates.id and compiling from its composition,
-- publish_rule_composition takes the raw composition directly — the
-- caller picks the trigger shape, the condition shapes, and the
-- consequence shapes, with their per-piece configs. Validates
-- everything against the rule_shapes catalog before persisting.
--
-- Why
-- ===
-- Templates assume every group needs the same rules. They don't —
-- groups govern themselves with rules that emerge from their
-- particular context. The Rule Composer (iOS coordinator landing in
-- a sibling commit) lets the user compose freely from primitives;
-- this RPC is the persistence endpoint behind it.
--
-- Templates stay as seed patterns / inspiration ("start from an
-- example") — they still go through publish_rule_version for now.
-- Eventually publish_rule_version becomes a thin wrapper that loads
-- the template and forwards to this RPC.
--
-- Signature
-- =========
-- publish_rule_composition(
--   p_group_id      uuid,
--   p_name          text,              -- user-facing rule name
--   p_scope         jsonb,             -- {type: "resource"|"series"|"group", id?: uuid}
--   p_trigger       jsonb,             -- {shape_id, config}
--   p_conditions    jsonb,             -- [{shape_id, config}, …]   (0..N, AND)
--   p_consequences  jsonb,             -- [{shape_id, config}, …]   (1..N, in order)
--   p_change_reason text default null
-- ) returns jsonb {rule_id, rule_version_id, version, conflicts}
--
-- Validation
-- ==========
--   1. Caller has has_permission('modifyRules') (matches mig 00235).
--   2. Group exists.
--   3. Scope type is in {resource, series, group}; id required for the
--      first two.
--   4. Trigger shape_id exists in rule_shapes, kind=trigger.
--   5. Trigger's valid_scopes contains the requested scope type
--      (empty list = universal).
--   6. Trigger's valid_resource_types contains the scope's resource_type
--      (empty list = universal). Lookup the resource_type from
--      public.resources when scope.type='resource'; from
--      public.resource_series → public.resources when scope.type='series';
--      skip the check when scope.type='group'.
--   7. Each condition.shape_id exists, kind=condition.
--   8. Each consequence.shape_id exists, kind=consequence.
--   9. At least one consequence.
--
-- Conflict detection
-- ==================
-- Re-uses the same same_scope_overlapping check as publish_rule_version:
-- another active rule_version in the group with the same trigger
-- eventType + same scope is flagged as warning (not blocking). Caller
-- decides whether to keep both.
--
-- Versioning
-- ==========
-- INSERT a new rules row + a new rule_versions row (version=1). Like
-- publish_rule_version, this is treated as a brand-new rule, not a
-- new version of an existing one (the composer doesn't surface
-- "edit existing" yet — that's a follow-up using a new RPC like
-- bump_rule_version).
--
-- Idempotent: not idempotent on retry — each call creates a fresh
-- rules row. Callers should de-dup at the client.
--
-- Rollback: _rollbacks/00245_rollback.sql drops the function.

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
  -- 0. Auth + permission gate (mirrors publish_rule_version mig 00235).
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.has_permission(p_group_id, v_uid, 'modifyRules') then
    raise exception 'modifyRules permission required' using errcode = '42501';
  end if;

  -- 1. Basic shape validations.
  if length(coalesce(trim(p_name), '')) < 2 then
    raise exception 'rule name must be at least 2 characters' using errcode = '22023';
  end if;
  if p_trigger is null or jsonb_typeof(p_trigger) <> 'object' then
    raise exception 'trigger required (jsonb object with shape_id + config)' using errcode = '22023';
  end if;
  if jsonb_typeof(p_consequences) <> 'array' or jsonb_array_length(p_consequences) = 0 then
    raise exception 'at least one consequence required' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_conditions, '[]'::jsonb)) <> 'array' then
    raise exception 'conditions must be a jsonb array' using errcode = '22023';
  end if;

  -- 2. Scope parse + resource_type resolution.
  v_scope_type := coalesce(p_scope->>'type', 'group');
  if v_scope_type not in ('resource','series','group') then
    raise exception 'unsupported scope.type=%', v_scope_type using errcode = '22023';
  end if;

  if v_scope_type = 'resource' then
    v_scope_id := nullif(p_scope->>'id','')::uuid;
    if v_scope_id is null then
      raise exception 'scope.id required for type=resource' using errcode = '22023';
    end if;
    select resource_type into v_resource_type from public.resources where id = v_scope_id;
    if v_resource_type is null then
      raise exception 'resource % not found', v_scope_id using errcode = '22023';
    end if;
    v_resource_id := v_scope_id;
  elsif v_scope_type = 'series' then
    v_scope_id := nullif(p_scope->>'id','')::uuid;
    if v_scope_id is null then
      raise exception 'scope.id required for type=series' using errcode = '22023';
    end if;
    -- A series has the same resource_type as its members; sample one.
    select r.resource_type into v_resource_type
      from public.resources r
     where r.series_id = v_scope_id
     limit 1;
    v_series_id := v_scope_id;
    -- v_resource_type may be null for an empty series — skip the
    -- trigger.valid_resource_types check in that case.
  end if;

  -- 3. Trigger shape lookup + scope/resource_type compatibility.
  v_trigger_id := p_trigger->>'shape_id';
  v_trigger_config := coalesce(p_trigger->'config', '{}'::jsonb);
  if v_trigger_id is null then
    raise exception 'trigger.shape_id required' using errcode = '22023';
  end if;
  select valid_scopes, valid_resource_types
    into v_trigger_valid_scopes, v_trigger_valid_resource_types
    from public.rule_shapes
   where id = v_trigger_id and kind = 'trigger';
  if not found then
    raise exception 'trigger shape % not found (or wrong kind)', v_trigger_id using errcode = '22023';
  end if;
  if v_trigger_valid_scopes is not null
     and array_length(v_trigger_valid_scopes, 1) > 0
     and not (v_scope_type = any (v_trigger_valid_scopes)) then
    raise exception 'trigger % does not support scope=%', v_trigger_id, v_scope_type using errcode = '22023';
  end if;
  if v_resource_type is not null
     and v_trigger_valid_resource_types is not null
     and array_length(v_trigger_valid_resource_types, 1) > 0
     and not (v_resource_type = any (v_trigger_valid_resource_types)) then
    raise exception 'trigger % does not support resource_type=% (valid: %)',
      v_trigger_id, v_resource_type, v_trigger_valid_resource_types
      using errcode = '22023';
  end if;

  -- 4. Condition shapes exist + are conditions.
  v_clean_conds := '[]'::jsonb;
  for v_cond in select * from jsonb_array_elements(coalesce(p_conditions, '[]'::jsonb))
  loop
    v_cond_id := v_cond->>'shape_id';
    if v_cond_id is null then
      raise exception 'condition.shape_id required (entry: %)', v_cond using errcode = '22023';
    end if;
    if not exists (select 1 from public.rule_shapes where id = v_cond_id and kind = 'condition') then
      raise exception 'condition shape % not found (or wrong kind)', v_cond_id using errcode = '22023';
    end if;
    v_clean_conds := v_clean_conds || jsonb_build_array(jsonb_build_object(
      'type',   v_cond_id,
      'config', coalesce(v_cond->'config', '{}'::jsonb)
    ));
  end loop;

  -- 5. Consequence shapes exist + are consequences.
  v_clean_cons := '[]'::jsonb;
  for v_cons in select * from jsonb_array_elements(p_consequences)
  loop
    v_cons_id := v_cons->>'shape_id';
    if v_cons_id is null then
      raise exception 'consequence.shape_id required (entry: %)', v_cons using errcode = '22023';
    end if;
    if not exists (select 1 from public.rule_shapes where id = v_cons_id and kind = 'consequence') then
      raise exception 'consequence shape % not found (or wrong kind)', v_cons_id using errcode = '22023';
    end if;
    v_clean_cons := v_clean_cons || jsonb_build_array(jsonb_build_object(
      'type',   v_cons_id,
      'config', coalesce(v_cons->'config', '{}'::jsonb)
    ));
  end loop;

  -- 6. Compile.
  v_compiled := jsonb_build_object(
    'trigger',      jsonb_build_object('eventType', v_trigger_id, 'config', v_trigger_config),
    'conditions',   v_clean_conds,
    'consequences', v_clean_cons,
    'exceptions',   '[]'::jsonb,
    'scope',        p_scope,
    'target',       jsonb_build_object('type','ref','value','$trigger.actor'),
    'shape_ids',    jsonb_build_object(
                      'trigger',      v_trigger_id,
                      'conditions',   (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_conds) c),
                      'consequences', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_cons) c)
                    )
  );

  -- 7. Conflict detection (same pattern as publish_rule_version):
  for v_against in (
    select rv.id as rv_id, r2.name as r_title
      from public.rule_versions rv
      join public.rules r2 on r2.id = rv.rule_id
     where r2.group_id = p_group_id
       and rv.status   = 'active'
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

  -- 8. Insert rule + first version.
  insert into public.rules (
    group_id, name, trigger, conditions, consequences,
    is_active, slug,
    resource_id, series_id, membership_id, module_key,
    proposed_by, created_at, updated_at
  )
  values (
    p_group_id, trim(p_name),
    v_compiled->'trigger', v_compiled->'conditions', v_compiled->'consequences',
    true,
    null,                       -- composition rules don't carry a template slug
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
    v_rule_id, 1,
    null,                       -- no template — free composition
    '{}'::jsonb,
    v_compiled,
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

revoke execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text) from public, anon;
grant  execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text) to authenticated, service_role;

comment on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text) is
  'Free-composition publish endpoint (mig 00245): caller assembles trigger + N conditions + N consequences from the rule_shapes catalog. Validates compatibility against the trigger shape''s valid_scopes + valid_resource_types. Companion to publish_rule_version (template-driven). Both write into the same rules + rule_versions tables.';
