-- 00251 — §22.4 Tree-based rule conditions (AND/OR/NOT).
--
-- Before: `rules.conditions` is a flat jsonb array; the engine evaluates
-- it as a single AND, forcing "Si A ó B" rules to be duplicated. Anti-
-- composable; Constitution §18 (Talmud) and Plans/Active/Governance.md
-- §22.4 close that gap.
--
-- After: `rules.conditions` accepts EITHER
--   (a) a JSON array of `{type,config}` leaves — legacy implicit AND
--       (every pre-§22.4 rule keeps working unmodified), OR
--   (b) a tree node `{op,children}` with op ∈ {and, or, not} and each
--       child being itself a leaf or nested node.
--
-- This migration:
--   1. Adds `public.validate_condition_node(jsonb)` — recursive validator
--      enforcing op enum + arity (not = 1 child, and/or ≥ 1) + leaf
--      shape. Pure function, callable from any RPC.
--   2. Adds `public.compile_condition_tree(jsonb)` — transforms an
--      author-shaped tree (`shape_id`+`config` on leaves) into the
--      engine-shaped form (`type`+`config`), preserving the structure.
--   3. Adds `public.extract_condition_shape_ids(jsonb)` — flat pre-order
--      list of every leaf shape id, used for `compiled.shape_ids.conditions`
--      so capability/conflict consumers don't learn the tree shape.
--   4. Bumps `public.publish_rule_composition` to v6: accepts a tree
--      under `p_conditions` (still tolerates the legacy array form),
--      compiles it into `rule_versions.compiled.conditions` preserving
--      the tree, and calls the validator before persisting.
--   5. Bumps `public.bump_rule_version` to v5: same tree acceptance +
--      validation on the edit-in-place path so an admin can flip a
--      live rule from "A and B" to "A and (B or C)" without re-creating.
--
-- Exceptions (`rule_versions.compiled.exceptions[]`) stay flat — they're
-- already implicitly OR'd ("any blocks") so a tree there adds complexity
-- without expressive gain (preserves §22.2 semantics, mig 00248).
--
-- Compatibility:
--   - Rule shapes still come from `public.rule_shapes`; tree leaves
--     reference shape ids identically to how flat leaves did.
--   - `compiled.shape_ids.conditions` now lists every leaf id from
--     anywhere in the tree (flat array view of the tree's leaves) so
--     downstream consumers (capability checks, conflict signatures)
--     keep working without learning the tree shape.

-- =============================================================================
-- 1. validate_condition_node — recursive structural validator.
-- =============================================================================
-- Returns the input on success; raises 22023 with an actionable message
-- on malformed shapes. NULL → returns NULL (callers coalesce to
-- '[]'::jsonb before invoking, so the validator never sees NULL in
-- practice). The validator does NOT check that leaf `type` strings
-- exist in `rule_shapes` — that's the RPC's job (it already validates
-- with kind=condition). Keeping shape lookup separate lets the
-- validator stay IMMUTABLE.

create or replace function public.validate_condition_node(p_node jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_op       text;
  v_children jsonb;
  v_child    jsonb;
  v_type     text;
  v_config   jsonb;
begin
  if p_node is null then
    return p_node;
  end if;

  -- Array form — recurse into each element as an implicit AND.
  if jsonb_typeof(p_node) = 'array' then
    for v_child in select * from jsonb_array_elements(p_node) loop
      perform public.validate_condition_node(v_child);
    end loop;
    return p_node;
  end if;

  if jsonb_typeof(p_node) <> 'object' then
    raise exception 'condition node must be object or array, got %', jsonb_typeof(p_node)
      using errcode = '22023';
  end if;

  -- Tree node — must have an `op` of and/or/not.
  if p_node ? 'op' then
    v_op       := p_node->>'op';
    v_children := p_node->'children';
    if v_op not in ('and', 'or', 'not') then
      raise exception 'invalid condition op %, expected and/or/not', v_op
        using errcode = '22023';
    end if;
    if v_children is null or jsonb_typeof(v_children) <> 'array' then
      raise exception 'condition op % requires children array', v_op
        using errcode = '22023';
    end if;
    if v_op = 'not' and jsonb_array_length(v_children) <> 1 then
      raise exception 'condition op not requires exactly 1 child, got %',
        jsonb_array_length(v_children)
        using errcode = '22023';
    end if;
    if v_op in ('and', 'or') and jsonb_array_length(v_children) = 0 then
      raise exception 'condition op % requires at least 1 child', v_op
        using errcode = '22023';
    end if;
    for v_child in select * from jsonb_array_elements(v_children) loop
      perform public.validate_condition_node(v_child);
    end loop;
    return p_node;
  end if;

  -- Leaf — must have a non-empty `type` AND `config` (object|null|absent).
  -- The publish RPCs use `shape_id` instead of `type` (their own
  -- convention pre-compile) — accept either here so the validator can
  -- run both on raw author input and on already-compiled snapshots.
  if not (p_node ? 'type' or p_node ? 'shape_id') then
    raise exception 'condition leaf missing required key: type or shape_id (or tree key: op)'
      using errcode = '22023';
  end if;
  v_type := coalesce(p_node->>'type', p_node->>'shape_id');
  if v_type is null or length(trim(v_type)) = 0 then
    raise exception 'condition leaf.type/shape_id must be non-empty'
      using errcode = '22023';
  end if;
  if p_node ? 'config' then
    v_config := p_node->'config';
    if v_config is not null
       and jsonb_typeof(v_config) not in ('object', 'null') then
      raise exception 'condition leaf.config must be object or null, got %',
        jsonb_typeof(v_config)
        using errcode = '22023';
    end if;
  end if;
  return p_node;
end;
$$;

comment on function public.validate_condition_node(jsonb) is
  'Recursively validates a rule-conditions jsonb body. Accepts the legacy flat-array shape (implicit AND) and the §22.4 tree shape `{op,children}` with op ∈ {and,or,not}. Raises 22023 with an actionable message on malformed bodies. Leaf shape recognition tolerates either `type` (compiled form) or `shape_id` (RPC author input). Used by publish_rule_composition and bump_rule_version.';

-- =============================================================================
-- 2. Helpers — compile + leaf-id extraction from an arbitrary tree.
-- =============================================================================
-- `compile_condition_tree` walks an author-shaped tree (`shape_id`+`config`
-- on leaves) and returns the engine-shaped form (`type`+`config` on
-- leaves). It also enforces the same shape-existence check the legacy
-- array path did, so an unknown leaf id raises before the tree lands in
-- `rule_versions.compiled`.

create or replace function public.compile_condition_tree(p_node jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_op       text;
  v_child    jsonb;
  v_out      jsonb;
  v_compiled jsonb;
  v_shape_id text;
begin
  if p_node is null then
    return '[]'::jsonb;
  end if;

  -- Array form — compile each leaf into a {type,config} object and
  -- return the same array shape. Preserves the legacy compiled wire so
  -- pre-§22.4 templates and rules don't shift shape.
  if jsonb_typeof(p_node) = 'array' then
    v_out := '[]'::jsonb;
    for v_child in select * from jsonb_array_elements(p_node) loop
      v_shape_id := v_child->>'shape_id';
      if v_shape_id is null then
        raise exception 'condition.shape_id required (entry: %)', v_child
          using errcode = '22023';
      end if;
      if not exists (select 1 from public.rule_shapes where id = v_shape_id and kind = 'condition') then
        raise exception 'condition shape % not found (or wrong kind)', v_shape_id
          using errcode = '22023';
      end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'type',   v_shape_id,
        'config', coalesce(v_child->'config', '{}'::jsonb)
      ));
    end loop;
    return v_out;
  end if;

  if jsonb_typeof(p_node) <> 'object' then
    raise exception 'condition tree node must be object or array, got %', jsonb_typeof(p_node)
      using errcode = '22023';
  end if;

  -- Tree node — recurse into children, preserving the op.
  if p_node ? 'op' then
    v_op := p_node->>'op';
    v_compiled := '[]'::jsonb;
    for v_child in select * from jsonb_array_elements(coalesce(p_node->'children', '[]'::jsonb)) loop
      v_compiled := v_compiled || jsonb_build_array(public.compile_condition_tree(v_child));
    end loop;
    return jsonb_build_object('op', v_op, 'children', v_compiled);
  end if;

  -- Leaf object — same {shape_id,config} → {type,config} transform.
  v_shape_id := p_node->>'shape_id';
  if v_shape_id is null then
    raise exception 'condition.shape_id required (entry: %)', p_node
      using errcode = '22023';
  end if;
  if not exists (select 1 from public.rule_shapes where id = v_shape_id and kind = 'condition') then
    raise exception 'condition shape % not found (or wrong kind)', v_shape_id
      using errcode = '22023';
  end if;
  return jsonb_build_object(
    'type',   v_shape_id,
    'config', coalesce(p_node->'config', '{}'::jsonb)
  );
end;
$$;

comment on function public.compile_condition_tree(jsonb) is
  'Transforms an author-shaped condition body (`shape_id`+`config` on leaves) into the engine-shaped form (`type`+`config`), preserving the AND/OR/NOT tree structure. Accepts both the flat array (legacy) and `{op,children}` tree shapes. Raises 22023 when a leaf references an unknown shape id.';

create or replace function public.extract_condition_shape_ids(p_node jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_child jsonb;
  v_out   jsonb := '[]'::jsonb;
  v_inner jsonb;
  v_id    jsonb;
begin
  if p_node is null then
    return '[]'::jsonb;
  end if;
  if jsonb_typeof(p_node) = 'array' then
    for v_child in select * from jsonb_array_elements(p_node) loop
      v_inner := public.extract_condition_shape_ids(v_child);
      for v_id in select * from jsonb_array_elements(v_inner) loop
        v_out := v_out || jsonb_build_array(v_id);
      end loop;
    end loop;
    return v_out;
  end if;
  if jsonb_typeof(p_node) <> 'object' then
    return '[]'::jsonb;
  end if;
  if p_node ? 'op' then
    return public.extract_condition_shape_ids(coalesce(p_node->'children', '[]'::jsonb));
  end if;
  -- Leaf — emit the id (whichever key carries it).
  if (p_node ? 'type') then
    return jsonb_build_array(p_node->>'type');
  end if;
  if (p_node ? 'shape_id') then
    return jsonb_build_array(p_node->>'shape_id');
  end if;
  return '[]'::jsonb;
end;
$$;

comment on function public.extract_condition_shape_ids(jsonb) is
  'Flat pre-order list of every leaf shape id anywhere in a condition body (array or tree). Used to populate compiled.shape_ids.conditions so downstream consumers see the same flat view they did pre-§22.4 without learning the tree shape.';

-- =============================================================================
-- 3. publish_rule_composition v6 — tree acceptance + validation.
-- =============================================================================
-- Same author surface as v5 (mig 00244) except `p_conditions` now
-- accepts EITHER a flat array of `{shape_id,config}` leaves OR a
-- `{op,children}` tree where each leaf is `{shape_id,config}`. The
-- compiled `rule_versions.compiled.conditions` mirrors the input
-- shape so `runRulesForEvent` can evaluate it directly.

create or replace function public.publish_rule_composition(
  p_group_id      uuid,
  p_name          text,
  p_scope         jsonb,
  p_trigger       jsonb,
  p_conditions    jsonb default '[]'::jsonb,
  p_consequences  jsonb default '[]'::jsonb,
  p_change_reason text default null,
  p_slug          text default null,
  p_exceptions    jsonb default '[]'::jsonb,
  p_membership_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_scope_type text; v_scope_id uuid; v_resource_type text;
  v_trigger_id text; v_trigger_config jsonb;
  v_trigger_valid_scopes text[]; v_trigger_valid_resource_types text[];
  v_cons jsonb; v_cons_id text; v_first_cons_id text; v_cons_target text;
  v_exc jsonb; v_exc_id text;
  v_compiled jsonb; v_rule_id uuid; v_rule_version_id uuid;
  v_resource_id uuid; v_series_id uuid;
  v_conflicts jsonb := '[]'::jsonb; v_against record;
  v_clean_conds jsonb;
  v_cond_shape_ids jsonb;
  v_clean_cons jsonb;
  v_clean_excs jsonb;
  v_slug text; v_slug_taken boolean;
  v_cons_object jsonb;
  v_membership_user_id uuid;
  v_conditions_input jsonb := coalesce(p_conditions, '[]'::jsonb);
begin
  if v_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if not public.has_permission(p_group_id, v_uid, 'modifyRules') then raise exception 'modifyRules permission required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'rule name must be at least 2 characters' using errcode = '22023'; end if;
  if p_trigger is null or jsonb_typeof(p_trigger) <> 'object' then raise exception 'trigger required' using errcode = '22023'; end if;
  if jsonb_typeof(p_consequences) <> 'array' or jsonb_array_length(p_consequences) = 0 then raise exception 'at least one consequence required' using errcode = '22023'; end if;
  -- §22.4: conditions may now be array (legacy AND) or tree object.
  if jsonb_typeof(v_conditions_input) not in ('array', 'object') then
    raise exception 'conditions must be a jsonb array or {op,children} object' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_exceptions, '[]'::jsonb)) <> 'array' then raise exception 'exceptions must be a jsonb array' using errcode = '22023'; end if;

  -- §22.4: structural validation of the tree happens up-front so a
  -- malformed body never reaches the compile step.
  perform public.validate_condition_node(v_conditions_input);

  if p_membership_id is not null then
    select user_id into v_membership_user_id from public.group_members
     where id = p_membership_id and group_id = p_group_id and active = true;
    if v_membership_user_id is null then
      raise exception 'membership_id % is not an active member of group %', p_membership_id, p_group_id
        using errcode = '22023';
    end if;
  end if;

  v_scope_type := coalesce(p_scope->>'type', 'group');
  if v_scope_type not in ('resource','series','group') then raise exception 'unsupported scope.type=%', v_scope_type using errcode = '22023'; end if;
  if v_scope_type = 'resource' then
    v_scope_id := nullif(p_scope->>'id','')::uuid;
    if v_scope_id is null then raise exception 'scope.id required for type=resource' using errcode = '22023'; end if;
    select resource_type into v_resource_type from public.resources where id = v_scope_id;
    if v_resource_type is null then raise exception 'resource % not found', v_scope_id using errcode = '22023'; end if;
    v_resource_id := v_scope_id;
  elsif v_scope_type = 'series' then
    v_scope_id := nullif(p_scope->>'id','')::uuid;
    if v_scope_id is null then raise exception 'scope.id required for type=series' using errcode = '22023'; end if;
    select r.resource_type into v_resource_type from public.resources r where r.series_id = v_scope_id limit 1;
    v_series_id := v_scope_id;
  end if;

  v_trigger_id := p_trigger->>'shape_id';
  v_trigger_config := coalesce(p_trigger->'config', '{}'::jsonb);
  if v_trigger_id is null then raise exception 'trigger.shape_id required' using errcode = '22023'; end if;
  select valid_scopes, valid_resource_types into v_trigger_valid_scopes, v_trigger_valid_resource_types
    from public.rule_shapes where id = v_trigger_id and kind = 'trigger';
  if not found then raise exception 'trigger shape % not found (or wrong kind)', v_trigger_id using errcode = '22023'; end if;
  if v_trigger_valid_scopes is not null and array_length(v_trigger_valid_scopes, 1) > 0
     and not (v_scope_type = any (v_trigger_valid_scopes)) then
    raise exception 'trigger % does not support scope=%', v_trigger_id, v_scope_type using errcode = '22023';
  end if;
  if v_resource_type is not null and v_trigger_valid_resource_types is not null
     and array_length(v_trigger_valid_resource_types, 1) > 0
     and not (v_resource_type = any (v_trigger_valid_resource_types)) then
    raise exception 'trigger % does not support resource_type=%', v_trigger_id, v_resource_type using errcode = '22023';
  end if;

  -- §22.4: compile the conditions body. If the input is a flat array
  -- the helper returns the same flat compiled array (legacy wire);
  -- if it's a tree the helper preserves the structure.
  v_clean_conds    := public.compile_condition_tree(v_conditions_input);
  v_cond_shape_ids := public.extract_condition_shape_ids(v_clean_conds);

  v_clean_cons := '[]'::jsonb;
  for v_cons in select * from jsonb_array_elements(p_consequences) loop
    v_cons_id := v_cons->>'shape_id';
    if v_first_cons_id is null then v_first_cons_id := v_cons_id; end if;
    if v_cons_id is null then raise exception 'consequence.shape_id required (entry: %)', v_cons using errcode = '22023'; end if;
    if not exists (select 1 from public.rule_shapes where id = v_cons_id and kind = 'consequence') then
      raise exception 'consequence shape % not found (or wrong kind)', v_cons_id using errcode = '22023';
    end if;
    v_cons_target := nullif(v_cons->>'target', '');
    if not public.validate_consequence_target(v_cons_target) then
      raise exception 'invalid consequence.target %: must be null, $trigger.actor, $resource.host, or $role.<role_id>', v_cons_target using errcode = '22023';
    end if;
    v_cons_object := jsonb_build_object('type', v_cons_id, 'config', coalesce(v_cons->'config', '{}'::jsonb));
    if v_cons_target is not null and v_cons_target <> '$trigger.actor' then
      v_cons_object := v_cons_object || jsonb_build_object('target', v_cons_target);
    end if;
    v_clean_cons := v_clean_cons || jsonb_build_array(v_cons_object);
  end loop;

  v_clean_excs := '[]'::jsonb;
  for v_exc in select * from jsonb_array_elements(coalesce(p_exceptions, '[]'::jsonb)) loop
    v_exc_id := v_exc->>'shape_id';
    if v_exc_id is null then raise exception 'exception.shape_id required (entry: %)', v_exc using errcode = '22023'; end if;
    if not exists (select 1 from public.rule_shapes where id = v_exc_id and kind = 'condition') then
      raise exception 'exception shape % not found (must be a condition shape)', v_exc_id using errcode = '22023';
    end if;
    v_clean_excs := v_clean_excs || jsonb_build_array(jsonb_build_object('type', v_exc_id, 'config', coalesce(v_exc->'config', '{}'::jsonb)));
  end loop;

  if p_slug is not null and length(trim(p_slug)) > 0 then
    v_slug := lower(trim(p_slug));
    if v_slug !~ '^[a-z][a-z0-9_]{0,63}$' then raise exception 'invalid slug %: must match [a-z][a-z0-9_]{0,63}', v_slug using errcode = '22023'; end if;
  else
    v_slug := public.slugify_camel(v_trigger_id) || '_' || public.slugify_camel(coalesce(v_first_cons_id, 'rule')) || '_' || lower(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  end if;
  select exists (select 1 from public.rules where group_id = p_group_id and slug = v_slug) into v_slug_taken;
  if v_slug_taken then
    if p_slug is not null then raise exception 'slug % already exists in this group', v_slug using errcode = '23505'; end if;
    v_slug := public.slugify_camel(v_trigger_id) || '_' || public.slugify_camel(coalesce(v_first_cons_id, 'rule')) || '_' || lower(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  end if;

  v_compiled := jsonb_build_object(
    'trigger', jsonb_build_object('eventType', v_trigger_id, 'config', v_trigger_config),
    'conditions', v_clean_conds, 'consequences', v_clean_cons, 'exceptions', v_clean_excs,
    'scope', p_scope,
    'membership_id', p_membership_id,
    'target', jsonb_build_object('type','ref','value','$trigger.actor'),
    'shape_ids', jsonb_build_object(
      'trigger', v_trigger_id,
      -- §22.4: shape_ids.conditions is the flat pre-order leaf list,
      -- not the tree, so capability checks + conflict signatures
      -- continue seeing the same shape they did pre-tree.
      'conditions', v_cond_shape_ids,
      'consequences', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_cons) c),
      'exceptions', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_excs) c)),
    'slug', v_slug);

  for v_against in (
    select rv.id as rv_id, r2.name as r_title
      from public.rule_versions rv join public.rules r2 on r2.id = rv.rule_id
     where r2.group_id = p_group_id and rv.status = 'active'
       and rv.compiled->'trigger'->>'eventType' = v_trigger_id
       and coalesce(rv.compiled->'scope', '{}'::jsonb) = p_scope
  ) loop
    v_conflicts := v_conflicts || jsonb_build_object('type', 'same_scope_overlapping', 'severity', 'warning', 'against_rule_version_id', v_against.rv_id, 'against_rule_title', v_against.r_title);
  end loop;

  insert into public.rules (group_id, name, trigger, conditions, consequences, exceptions, is_active, slug, resource_id, series_id, membership_id, module_key, proposed_by, created_at, updated_at)
  values (p_group_id, trim(p_name), v_compiled->'trigger', v_compiled->'conditions', v_compiled->'consequences', v_compiled->'exceptions', true, v_slug, v_resource_id, v_series_id, p_membership_id, null, v_uid, now(), now())
  returning id into v_rule_id;

  insert into public.rule_versions (rule_id, version, template_id, shape_params, compiled, status, effective_from, effective_until, previous_version_id, created_by, change_reason)
  values (v_rule_id, 1, null, '{}'::jsonb, v_compiled, 'active', now(), null, null, v_uid, p_change_reason)
  returning id into v_rule_version_id;

  if jsonb_array_length(v_conflicts) > 0 then
    insert into public.rule_conflicts (group_id, rule_a_version_id, rule_b_version_id, conflict_type, severity)
    select p_group_id, v_rule_version_id, (c->>'against_rule_version_id')::uuid, c->>'type', c->>'severity' from jsonb_array_elements(v_conflicts) as c;
  end if;

  return jsonb_build_object('rule_id', v_rule_id, 'rule_version_id', v_rule_version_id, 'version', 1, 'slug', v_slug, 'conflicts', v_conflicts);
end;
$$;

comment on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb, uuid) is
  'v6 (§22.4): admin-only publish of a per-piece rule composition. `p_conditions` now accepts EITHER a flat array of `{shape_id,config}` leaves OR a `{op,children}` AND/OR/NOT tree. The compiled snapshot in `rule_versions.compiled.conditions` preserves the tree shape; `compiled.shape_ids.conditions` is always the flat pre-order leaf list so capability/conflict consumers stay unchanged. Validates the tree via validate_condition_node before persisting.';

-- =============================================================================
-- 4. bump_rule_version v5 — same tree acceptance + validation on edit-in-place.
-- =============================================================================

create or replace function public.bump_rule_version(
  p_rule_id           uuid,
  p_name              text,
  p_trigger           jsonb,
  p_conditions        jsonb default '[]'::jsonb,
  p_consequences      jsonb default '[]'::jsonb,
  p_change_reason     text default null,
  p_exceptions        jsonb default null,
  p_membership_id     uuid default null,
  p_clear_membership  boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_rule public.rules%rowtype; v_active public.rule_versions%rowtype;
  v_trigger_id text; v_trigger_config jsonb;
  v_trigger_valid_scopes text[]; v_trigger_valid_resource_types text[];
  v_scope jsonb; v_scope_type text; v_resource_type text;
  v_cons jsonb; v_cons_id text; v_cons_target text; v_cons_object jsonb;
  v_exc jsonb; v_exc_id text;
  v_clean_conds jsonb;
  v_cond_shape_ids jsonb;
  v_clean_cons jsonb;
  v_clean_excs jsonb;
  v_compiled jsonb; v_new_version_no int; v_new_version_id uuid;
  v_conflicts jsonb := '[]'::jsonb; v_against record;
  v_resolved_membership_id uuid;
  v_membership_user_id uuid;
  v_conditions_input jsonb := coalesce(p_conditions, '[]'::jsonb);
begin
  if v_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  select * into v_rule from public.rules where id = p_rule_id;
  if not found then raise exception 'rule % not found', p_rule_id using errcode = '02000'; end if;
  if not public.has_permission(v_rule.group_id, v_uid, 'modifyRules') then raise exception 'modifyRules permission required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'rule name must be at least 2 characters' using errcode = '22023'; end if;
  if p_trigger is null or jsonb_typeof(p_trigger) <> 'object' then raise exception 'trigger required' using errcode = '22023'; end if;
  if jsonb_typeof(p_consequences) <> 'array' or jsonb_array_length(p_consequences) = 0 then raise exception 'at least one consequence required' using errcode = '22023'; end if;
  -- §22.4: conditions may now be array (legacy AND) or tree object.
  if jsonb_typeof(v_conditions_input) not in ('array', 'object') then
    raise exception 'conditions must be a jsonb array or {op,children} object' using errcode = '22023';
  end if;
  if p_exceptions is not null and jsonb_typeof(p_exceptions) <> 'array' then raise exception 'exceptions must be a jsonb array' using errcode = '22023'; end if;

  perform public.validate_condition_node(v_conditions_input);

  if p_clear_membership then
    v_resolved_membership_id := null;
  elsif p_membership_id is not null then
    select user_id into v_membership_user_id from public.group_members
     where id = p_membership_id and group_id = v_rule.group_id and active = true;
    if v_membership_user_id is null then
      raise exception 'membership_id % is not an active member of group %', p_membership_id, v_rule.group_id
        using errcode = '22023';
    end if;
    v_resolved_membership_id := p_membership_id;
  else
    v_resolved_membership_id := v_rule.membership_id;
  end if;

  select * into v_active from public.rule_versions
   where rule_id = p_rule_id and status = 'active' order by version desc limit 1 for update;
  if not found then raise exception 'rule % has no active version to bump (deactivated or never published)', p_rule_id using errcode = '22023'; end if;

  v_scope := coalesce(v_active.compiled->'scope', jsonb_build_object('type','group'));
  v_scope_type := coalesce(v_scope->>'type', 'group');
  if v_scope_type = 'resource' then select resource_type into v_resource_type from public.resources where id = v_rule.resource_id;
  elsif v_scope_type = 'series' then select r.resource_type into v_resource_type from public.resources r where r.series_id = v_rule.series_id limit 1; end if;

  v_trigger_id := p_trigger->>'shape_id';
  v_trigger_config := coalesce(p_trigger->'config', '{}'::jsonb);
  if v_trigger_id is null then raise exception 'trigger.shape_id required' using errcode = '22023'; end if;
  select valid_scopes, valid_resource_types into v_trigger_valid_scopes, v_trigger_valid_resource_types from public.rule_shapes where id = v_trigger_id and kind = 'trigger';
  if not found then raise exception 'trigger shape % not found (or wrong kind)', v_trigger_id using errcode = '22023'; end if;
  if v_trigger_valid_scopes is not null and array_length(v_trigger_valid_scopes, 1) > 0
     and not (v_scope_type = any (v_trigger_valid_scopes)) then
    raise exception 'trigger % does not support scope=% (rule''s preserved scope)', v_trigger_id, v_scope_type using errcode = '22023';
  end if;
  if v_resource_type is not null and v_trigger_valid_resource_types is not null
     and array_length(v_trigger_valid_resource_types, 1) > 0
     and not (v_resource_type = any (v_trigger_valid_resource_types)) then
    raise exception 'trigger % does not support resource_type=%', v_trigger_id, v_resource_type using errcode = '22023';
  end if;

  v_clean_conds    := public.compile_condition_tree(v_conditions_input);
  v_cond_shape_ids := public.extract_condition_shape_ids(v_clean_conds);

  v_clean_cons := '[]'::jsonb;
  for v_cons in select * from jsonb_array_elements(p_consequences) loop
    v_cons_id := v_cons->>'shape_id';
    if v_cons_id is null then raise exception 'consequence.shape_id required (entry: %)', v_cons using errcode = '22023'; end if;
    if not exists (select 1 from public.rule_shapes where id = v_cons_id and kind = 'consequence') then
      raise exception 'consequence shape % not found (or wrong kind)', v_cons_id using errcode = '22023';
    end if;
    v_cons_target := nullif(v_cons->>'target', '');
    if not public.validate_consequence_target(v_cons_target) then
      raise exception 'invalid consequence.target %: must be null, $trigger.actor, $resource.host, or $role.<role_id>', v_cons_target using errcode = '22023';
    end if;
    v_cons_object := jsonb_build_object('type', v_cons_id, 'config', coalesce(v_cons->'config', '{}'::jsonb));
    if v_cons_target is not null and v_cons_target <> '$trigger.actor' then
      v_cons_object := v_cons_object || jsonb_build_object('target', v_cons_target);
    end if;
    v_clean_cons := v_clean_cons || jsonb_build_array(v_cons_object);
  end loop;

  if p_exceptions is null then
    v_clean_excs := coalesce(v_active.compiled->'exceptions', '[]'::jsonb);
  else
    v_clean_excs := '[]'::jsonb;
    for v_exc in select * from jsonb_array_elements(p_exceptions) loop
      v_exc_id := v_exc->>'shape_id';
      if v_exc_id is null then raise exception 'exception.shape_id required (entry: %)', v_exc using errcode = '22023'; end if;
      if not exists (select 1 from public.rule_shapes where id = v_exc_id and kind = 'condition') then
        raise exception 'exception shape % not found (must be a condition shape)', v_exc_id using errcode = '22023';
      end if;
      v_clean_excs := v_clean_excs || jsonb_build_array(jsonb_build_object('type', v_exc_id, 'config', coalesce(v_exc->'config', '{}'::jsonb)));
    end loop;
  end if;

  v_compiled := jsonb_build_object(
    'trigger', jsonb_build_object('eventType', v_trigger_id, 'config', v_trigger_config),
    'conditions', v_clean_conds, 'consequences', v_clean_cons, 'exceptions', v_clean_excs,
    'scope', v_scope,
    'membership_id', v_resolved_membership_id,
    'target', coalesce(v_active.compiled->'target', jsonb_build_object('type','ref','value','$trigger.actor')),
    'shape_ids', jsonb_build_object(
      'trigger', v_trigger_id,
      'conditions', v_cond_shape_ids,
      'consequences', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_cons) c),
      'exceptions', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_excs) c)),
    'slug', v_rule.slug);

  for v_against in (
    select rv.id as rv_id, r2.name as r_title
      from public.rule_versions rv join public.rules r2 on r2.id = rv.rule_id
     where r2.group_id = v_rule.group_id and rv.status = 'active'
       and rv.id <> v_active.id
       and rv.compiled->'trigger'->>'eventType' = v_trigger_id
       and coalesce(rv.compiled->'scope', '{}'::jsonb) = v_scope
  ) loop
    v_conflicts := v_conflicts || jsonb_build_object('type', 'same_scope_overlapping', 'severity', 'warning', 'against_rule_version_id', v_against.rv_id, 'against_rule_title', v_against.r_title);
  end loop;

  update public.rule_versions set status = 'superseded', effective_until = now() where id = v_active.id;
  v_new_version_no := v_active.version + 1;
  insert into public.rule_versions (rule_id, version, template_id, shape_params, compiled, status, effective_from, effective_until, previous_version_id, created_by, change_reason)
  values (p_rule_id, v_new_version_no, v_active.template_id, '{}'::jsonb, v_compiled, 'active', now(), null, v_active.id, v_uid, p_change_reason)
  returning id into v_new_version_id;

  update public.rules
     set name = trim(p_name), trigger = v_compiled->'trigger', conditions = v_compiled->'conditions',
         consequences = v_compiled->'consequences', exceptions = v_compiled->'exceptions',
         membership_id = v_resolved_membership_id,
         updated_at = now()
   where id = p_rule_id;

  if jsonb_array_length(v_conflicts) > 0 then
    insert into public.rule_conflicts (group_id, rule_a_version_id, rule_b_version_id, conflict_type, severity)
    select v_rule.group_id, v_new_version_id, (c->>'against_rule_version_id')::uuid, c->>'type', c->>'severity' from jsonb_array_elements(v_conflicts) as c;
  end if;

  return jsonb_build_object('rule_id', p_rule_id, 'rule_version_id', v_new_version_id, 'version', v_new_version_no, 'slug', v_rule.slug, 'conflicts', v_conflicts);
end;
$$;

comment on function public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb, uuid, boolean) is
  'v5 (§22.4): edit-in-place rule version bump. Same surface as v4 (mig 00250) but `p_conditions` now accepts EITHER a flat array (legacy AND) or a `{op,children}` AND/OR/NOT tree. Validates the tree via validate_condition_node before persisting. The compiled snapshot preserves the tree shape; `compiled.shape_ids.conditions` stays the flat pre-order leaf list.';
