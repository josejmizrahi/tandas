-- 00249 — Per-consequence target selector (schema only; engine in next mig).
--
-- §22.3 Governance.md — multi-target / subject distinto del actor.
-- Hoy `compiled.target` está hardcoded a `$trigger.actor` y todas las
-- consecuencias aplican al member_id que el trigger emite. Patrón
-- "anti-tirania" típico (notifica al tesorero cuando alguien intenta
-- retirar > $X) no es expresable sin reabrir la regla y crear un
-- permission gate paralelo.
--
-- Esta mig habilita SOLO la persistencia y validación del campo
-- `target` en cada consequence; el engine lo lee en el siguiente
-- commit. Permite que el composer iOS empiece a guardar reglas con
-- target seleccionable sin romper el comportamiento actual del engine
-- (que sigue resolviéndolo todo al $trigger.actor).
--
-- Selector vocabulary (Beta 1)
-- =============================
--   $trigger.actor     — default; el member_id del target emitido por
--                        el trigger. Comportamiento histórico.
--   $role.<role_id>    — multiplexa: la consecuencia se ejecuta una
--                        vez por cada member activo del grupo que
--                        tenga ese rol asignado. Ej:
--                        `$role.treasurer`, `$role.founder`.
--                        role_id valida [a-z][a-z0-9_]{0,31}.
--   $resource.host     — para resources tipo event: el member que
--                        figura en metadata.host_id.
--
-- Futuros (no Beta 1):
--   $member.<uuid>     — picker explícito; UI más cara, demand-pull bajo.
--   $resource.assignee — para slot resources.
--   $derived.<fn>      — funciones derivadas (multi-axis, etc.).
--
-- Cambios
-- =======
--   1. Helper `validate_consequence_target(text)` — regex check.
--   2. publish_rule_composition v4: cada elemento de p_consequences
--      acepta opcional `target` text. Default $trigger.actor.
--      Validación: si presente, debe matchear el vocabulary.
--   3. bump_rule_version v3: idem.
--   4. compiled.consequences[].target persistido en jsonb.
--
-- Comportamiento del engine
-- =========================
-- Sin cambio. El engine ignora `target` por ahora; sigue usando el
-- target.member_id del trigger. Esto es deliberado para que esta mig
-- sea risk-free: persiste un campo opcional, no cambia ejecución.
--
-- Rollback: _rollbacks/00249_rollback.sql restaura firmas previas y
-- dropea el helper.

-- =========================================================
-- 1. validate_consequence_target helper
-- =========================================================
create or replace function public.validate_consequence_target(p_target text)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog
as $$
  select p_target is null
      or p_target = '$trigger.actor'
      or p_target = '$resource.host'
      or p_target ~ '^\$role\.[a-z][a-z0-9_]{0,31}$';
$$;

revoke execute on function public.validate_consequence_target(text) from public, anon;
grant  execute on function public.validate_consequence_target(text) to authenticated, service_role;

comment on function public.validate_consequence_target(text) is
  'Returns true when the consequence target selector is in the Beta-1 vocabulary: null, $trigger.actor, $resource.host, or $role.<role_id>. Used by publish_rule_composition + bump_rule_version (mig 00249).';

-- =========================================================
-- 2. publish_rule_composition v4 — accepts per-consequence target
-- =========================================================
drop function if exists public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb);

create or replace function public.publish_rule_composition(
  p_group_id      uuid,
  p_name          text,
  p_scope         jsonb,
  p_trigger       jsonb,
  p_conditions    jsonb default '[]'::jsonb,
  p_consequences  jsonb default '[]'::jsonb,
  p_change_reason text default null,
  p_slug          text default null,
  p_exceptions    jsonb default '[]'::jsonb
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
  v_cond jsonb; v_cond_id text;
  v_cons jsonb; v_cons_id text; v_first_cons_id text; v_cons_target text;
  v_exc jsonb; v_exc_id text;
  v_compiled         jsonb;
  v_rule_id          uuid;
  v_rule_version_id  uuid;
  v_resource_id      uuid;
  v_series_id        uuid;
  v_conflicts        jsonb := '[]'::jsonb;
  v_against          record;
  v_clean_conds      jsonb;
  v_clean_cons       jsonb;
  v_clean_excs       jsonb;
  v_slug             text;
  v_slug_taken       boolean;
  v_cons_object      jsonb;
begin
  if v_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if not public.has_permission(p_group_id, v_uid, 'modifyRules') then raise exception 'modifyRules permission required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'rule name must be at least 2 characters' using errcode = '22023'; end if;
  if p_trigger is null or jsonb_typeof(p_trigger) <> 'object' then raise exception 'trigger required' using errcode = '22023'; end if;
  if jsonb_typeof(p_consequences) <> 'array' or jsonb_array_length(p_consequences) = 0 then raise exception 'at least one consequence required' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p_conditions, '[]'::jsonb)) <> 'array' then raise exception 'conditions must be a jsonb array' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p_exceptions, '[]'::jsonb)) <> 'array' then raise exception 'exceptions must be a jsonb array' using errcode = '22023'; end if;

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

  v_clean_conds := '[]'::jsonb;
  for v_cond in select * from jsonb_array_elements(coalesce(p_conditions, '[]'::jsonb)) loop
    v_cond_id := v_cond->>'shape_id';
    if v_cond_id is null then raise exception 'condition.shape_id required (entry: %)', v_cond using errcode = '22023'; end if;
    if not exists (select 1 from public.rule_shapes where id = v_cond_id and kind = 'condition') then
      raise exception 'condition shape % not found (or wrong kind)', v_cond_id using errcode = '22023';
    end if;
    v_clean_conds := v_clean_conds || jsonb_build_array(jsonb_build_object('type', v_cond_id, 'config', coalesce(v_cond->'config', '{}'::jsonb)));
  end loop;

  -- Consequences with optional target selector (mig 00249).
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
      raise exception 'invalid consequence.target %: must be null, $trigger.actor, $resource.host, or $role.<role_id>',
        v_cons_target using errcode = '22023';
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
    'target', jsonb_build_object('type','ref','value','$trigger.actor'),
    'shape_ids', jsonb_build_object(
      'trigger', v_trigger_id,
      'conditions', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_conds) c),
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
  values (p_group_id, trim(p_name), v_compiled->'trigger', v_compiled->'conditions', v_compiled->'consequences', v_compiled->'exceptions', true, v_slug, v_resource_id, v_series_id, null, null, v_uid, now(), now())
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

revoke execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb) from public, anon;
grant  execute on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb) to authenticated, service_role;
comment on function public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb) is 'v4 (mig 00249): consequences[].target opcional. Selectors: $trigger.actor (default), $resource.host, $role.<id>.';

-- =========================================================
-- 3. bump_rule_version v3 — accepts per-consequence target
-- =========================================================
drop function if exists public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb);

create or replace function public.bump_rule_version(
  p_rule_id uuid, p_name text, p_trigger jsonb,
  p_conditions jsonb default '[]'::jsonb,
  p_consequences jsonb default '[]'::jsonb,
  p_change_reason text default null,
  p_exceptions jsonb default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_rule public.rules%rowtype; v_active public.rule_versions%rowtype;
  v_trigger_id text; v_trigger_config jsonb;
  v_trigger_valid_scopes text[]; v_trigger_valid_resource_types text[];
  v_scope jsonb; v_scope_type text; v_resource_type text;
  v_cond jsonb; v_cond_id text;
  v_cons jsonb; v_cons_id text; v_cons_target text; v_cons_object jsonb;
  v_exc jsonb; v_exc_id text;
  v_clean_conds jsonb; v_clean_cons jsonb; v_clean_excs jsonb;
  v_compiled jsonb; v_new_version_no int; v_new_version_id uuid;
  v_conflicts jsonb := '[]'::jsonb; v_against record;
begin
  if v_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  select * into v_rule from public.rules where id = p_rule_id;
  if not found then raise exception 'rule % not found', p_rule_id using errcode = '02000'; end if;
  if not public.has_permission(v_rule.group_id, v_uid, 'modifyRules') then raise exception 'modifyRules permission required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'rule name must be at least 2 characters' using errcode = '22023'; end if;
  if p_trigger is null or jsonb_typeof(p_trigger) <> 'object' then raise exception 'trigger required' using errcode = '22023'; end if;
  if jsonb_typeof(p_consequences) <> 'array' or jsonb_array_length(p_consequences) = 0 then raise exception 'at least one consequence required' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p_conditions, '[]'::jsonb)) <> 'array' then raise exception 'conditions must be a jsonb array' using errcode = '22023'; end if;
  if p_exceptions is not null and jsonb_typeof(p_exceptions) <> 'array' then raise exception 'exceptions must be a jsonb array' using errcode = '22023'; end if;

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

  v_clean_conds := '[]'::jsonb;
  for v_cond in select * from jsonb_array_elements(coalesce(p_conditions, '[]'::jsonb)) loop
    v_cond_id := v_cond->>'shape_id';
    if v_cond_id is null then raise exception 'condition.shape_id required (entry: %)', v_cond using errcode = '22023'; end if;
    if not exists (select 1 from public.rule_shapes where id = v_cond_id and kind = 'condition') then
      raise exception 'condition shape % not found (or wrong kind)', v_cond_id using errcode = '22023';
    end if;
    v_clean_conds := v_clean_conds || jsonb_build_array(jsonb_build_object('type', v_cond_id, 'config', coalesce(v_cond->'config', '{}'::jsonb)));
  end loop;

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
    'target', coalesce(v_active.compiled->'target', jsonb_build_object('type','ref','value','$trigger.actor')),
    'shape_ids', jsonb_build_object(
      'trigger', v_trigger_id,
      'conditions', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_conds) c),
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
         consequences = v_compiled->'consequences', exceptions = v_compiled->'exceptions', updated_at = now()
   where id = p_rule_id;

  if jsonb_array_length(v_conflicts) > 0 then
    insert into public.rule_conflicts (group_id, rule_a_version_id, rule_b_version_id, conflict_type, severity)
    select v_rule.group_id, v_new_version_id, (c->>'against_rule_version_id')::uuid, c->>'type', c->>'severity' from jsonb_array_elements(v_conflicts) as c;
  end if;

  return jsonb_build_object('rule_id', p_rule_id, 'rule_version_id', v_new_version_id, 'version', v_new_version_no, 'slug', v_rule.slug, 'conflicts', v_conflicts);
end; $$;

revoke execute on function public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb) from public, anon;
grant  execute on function public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb) to authenticated, service_role;
comment on function public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb) is 'v3 (mig 00249): consequences[].target opcional, same vocabulary as publish_rule_composition.';
