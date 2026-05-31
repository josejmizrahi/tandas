-- 00246 — publish_rule_composition v2: stable slug for free compositions.
--
-- Closes the Constitution §7 + Social-Primitives §7 doctrine gap:
-- "rules need stable IDs that don't change with copy localization."
-- Composer-created rules (mig 00245) were landing with slug=NULL,
-- making them orphans for:
--   - selectMostSpecificPerSlug() in the engine (no scope override
--     possible because nothing to dedup against).
--   - Analytics rollups (slug is the stable grouping key).
--   - Future appeals/votes that reference the rule abstractly.
--   - Reading old atoms where rule_id changed across edits.
--
-- This migration extends publish_rule_composition with:
--   - Optional p_slug text parameter. When null, server auto-derives:
--       <trigger_slug>_<first_consequence_slug>_<6hex>
--     where slug = snake_case(shape_id). Example:
--       checkInRecorded + fine → check_in_recorded_fine_a1b2c3
--   - When non-null, validates format [a-z][a-z0-9_]{0,63} and
--     uniqueness within the group (group_id, slug). On conflict,
--     raises errcode 23505 with a clear message.
--   - The final slug lands in rules.slug and is returned in the
--     result envelope so the client can show "tu acuerdo se guardó
--     como check_in_recorded_fine_a1b2c3".
--
-- The existing rules_slug_idx (group_id, slug) is NOT a unique index
-- today — historical seeds use the same slug across groups by design.
-- We don't add a UNIQUE constraint at table level (would invalidate
-- existing data); enforcement happens inside the RPC instead.
--
-- Backward compat: arity-0..7 calls keep working — p_slug is
-- positional last with default null. Old callers (the one EventRulesSheet
-- has today) pass nothing and get auto-generation.
--
-- Idempotent: DROP + CREATE OR REPLACE. The previous 7-arg signature is
-- replaced with an 8-arg signature.
--
-- Rollback: _rollbacks/00246_rollback.sql restores the 7-arg signature.

drop function if exists public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text);

-- Slug helper: camelCase → snake_case. Idempotent on already-snake_case
-- input. Used to derive readable defaults from shape_ids like
-- `checkInRecorded` → `check_in_recorded`.
create or replace function public.slugify_camel(p_in text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select lower(regexp_replace(
    regexp_replace(coalesce(p_in, ''), '([a-z0-9])([A-Z])', '\1_\2', 'g'),
    '([A-Z]+)([A-Z][a-z])', '\1_\2', 'g'
  ));
$$;

revoke execute on function public.slugify_camel(text) from public, anon;
grant  execute on function public.slugify_camel(text) to authenticated, service_role;

comment on function public.slugify_camel(text) is
  'camelCase → snake_case. Used by publish_rule_composition to derive readable default slugs from shape ids (e.g. checkInRecorded → check_in_recorded).';

-- Main RPC with the new p_slug param.
create or replace function public.publish_rule_composition(
  p_group_id      uuid,
  p_name          text,
  p_scope         jsonb,
  p_trigger       jsonb,
  p_conditions    jsonb default '[]'::jsonb,
  p_consequences  jsonb default '[]'::jsonb,
  p_change_reason text default null,
  p_slug          text default null
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
  v_first_cons_id    text;
  v_compiled         jsonb;
  v_rule_id          uuid;
  v_rule_version_id  uuid;
  v_resource_id      uuid;
  v_series_id        uuid;
  v_conflicts        jsonb := '[]'::jsonb;
  v_against          record;
  v_clean_conds      jsonb;
  v_clean_cons       jsonb;
  v_slug             text;
  v_slug_taken       boolean;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.has_permission(p_group_id, v_uid, 'modifyRules') then
    raise exception 'modifyRules permission required' using errcode = '42501';
  end if;
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
    select r.resource_type into v_resource_type
      from public.resources r
     where r.series_id = v_scope_id
     limit 1;
    v_series_id := v_scope_id;
  end if;

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

  v_clean_cons := '[]'::jsonb;
  for v_cons in select * from jsonb_array_elements(p_consequences)
  loop
    v_cons_id := v_cons->>'shape_id';
    if v_first_cons_id is null then v_first_cons_id := v_cons_id; end if;
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

  -- Slug resolution. mig 00246: stable id for the rule, derived or
  -- user-provided. Validated against format + uniqueness in this group.
  if p_slug is not null and length(trim(p_slug)) > 0 then
    v_slug := lower(trim(p_slug));
    if v_slug !~ '^[a-z][a-z0-9_]{0,63}$' then
      raise exception 'invalid slug %: must match [a-z][a-z0-9_]{0,63}', v_slug
        using errcode = '22023';
    end if;
  else
    -- Auto-derive: <trigger_snake>_<first_cons_snake>_<6 hex chars>.
    -- 6 hex chars = 16.7M combinations — plenty for the within-group
    -- collision space (a group with even 100 rules has ~0.0006%
    -- collision odds). On the off chance one collides, the uniqueness
    -- check below loops once to regenerate.
    v_slug := public.slugify_camel(v_trigger_id)
              || '_' || public.slugify_camel(coalesce(v_first_cons_id, 'rule'))
              || '_' || lower(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  end if;

  -- Uniqueness check within the group. If user-provided and taken,
  -- raise. If auto-generated and somehow taken, regenerate once.
  select exists (
    select 1 from public.rules
     where group_id = p_group_id and slug = v_slug
  ) into v_slug_taken;
  if v_slug_taken then
    if p_slug is not null then
      raise exception 'slug % already exists in this group', v_slug using errcode = '23505';
    end if;
    -- Retry once with a fresh suffix.
    v_slug := public.slugify_camel(v_trigger_id)
              || '_' || public.slugify_camel(coalesce(v_first_cons_id, 'rule'))
              || '_' || lower(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  end if;

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
                    ),
    'slug',         v_slug
  );

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
    v_slug,
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
    null,
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
    'slug',            v_slug,
    'conflicts',       v_conflicts
  );
end;
$$;

revoke execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text) to authenticated, service_role;

comment on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text) is
  'v2 (mig 00246): adds optional p_slug. When null, server auto-derives <trigger_snake>_<first_cons_snake>_<6hex>. Closes Constitution doctrine gap: rules need stable IDs independent of localized copy. Returns the final slug in the result envelope.';
