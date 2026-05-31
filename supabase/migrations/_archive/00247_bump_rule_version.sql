-- 00247 — bump_rule_version: edit-in-place sin perder rule_id.
--
-- Cierra el gap §22.1 (Governance.md): hoy publish_rule_composition
-- siempre crea una fila nueva en `rules` con un rule_id distinto. Eso
-- significa que editar el monto de una multa (caso 1 de cualquier
-- beta tester) rompe la continuidad de atoms históricos: las fines
-- emitidas referencian el rule_id viejo + las nuevas el rule_id
-- nuevo.
--
-- Semántica
-- =========
-- bump_rule_version recibe un rule_id existente + la nueva composición
-- (trigger / conditions / consequences) y:
--
--   1. Verifica auth + has_permission('modifyRules') sobre el grupo
--      que es dueño de la regla.
--   2. Lee el rule_versions ACTIVO actual del rule (debe haber uno y
--      sólo uno por (rule_id, status='active')).
--   3. Marca el activo como 'superseded' + sella effective_until=now().
--   4. Inserta nuevo rule_versions con version+1, previous_version_id
--      apuntando al anterior, status='active', mismo template_id (o
--      null si es composer).
--   5. Actualiza rules SET name, trigger, conditions, consequences,
--      updated_at — preserva slug + scope (resource_id/series_id/
--      module_key/membership_id) + group_id.
--   6. Re-emite conflict detection contra otros rule_versions activos
--      del mismo grupo con mismo trigger.eventType + mismo scope
--      jsonb (igual que publish_rule_composition).
--   7. Devuelve el mismo envelope {rule_id, rule_version_id, version,
--      slug, conflicts}.
--
-- Decisiones explícitas
-- =====================
--   - SCOPE NO se puede cambiar via bump. Cambiar de scope.group a
--     scope.resource sería un rule conceptualmente distinto — los
--     atoms históricos quedarían sin contexto. Para "muevo esta regla
--     de aquí allá" el flujo correcto es: desactivar la vieja
--     (otro RPC, fuera de scope) + crear nueva.
--   - SLUG NO se puede cambiar via bump. El stable id es justo lo
--     que estamos preservando.
--   - TEMPLATE_ID se preserva del activo anterior. Si la regla nació
--     de un template, la nueva versión sigue marcada con el mismo
--     template_id (linaje). Si nació de composición libre, sigue
--     null. UI puede mostrarlo.
--   - Sólo el active queda activo. Si el rule no tiene un active
--     (porque alguien lo desactivó), bump falla con un mensaje claro.
--
-- Idempotencia
-- ============
-- NO es idempotente — cada llamada incrementa version. Cliente debe
-- de-duplicar (e.g. botón "Guardar cambios" desabilitado mientras
-- está in-flight, que ya tenemos en el coordinator).
--
-- Rollback: _rollbacks/00247_rollback.sql dropea el RPC.

create or replace function public.bump_rule_version(
  p_rule_id       uuid,
  p_name          text,
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
  v_rule             public.rules%rowtype;
  v_active           public.rule_versions%rowtype;
  v_trigger_id       text;
  v_trigger_config   jsonb;
  v_trigger_valid_scopes        text[];
  v_trigger_valid_resource_types text[];
  v_scope            jsonb;
  v_scope_type       text;
  v_resource_type    text;
  v_cond             jsonb;
  v_cond_id          text;
  v_cons             jsonb;
  v_cons_id          text;
  v_clean_conds      jsonb;
  v_clean_cons       jsonb;
  v_compiled         jsonb;
  v_new_version_no   int;
  v_new_version_id   uuid;
  v_conflicts        jsonb := '[]'::jsonb;
  v_against          record;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- 1. Load + authorize.
  select * into v_rule from public.rules where id = p_rule_id;
  if not found then
    raise exception 'rule % not found', p_rule_id using errcode = '02000';
  end if;
  if not public.has_permission(v_rule.group_id, v_uid, 'modifyRules') then
    raise exception 'modifyRules permission required' using errcode = '42501';
  end if;

  -- 2. Validate top-level shape inputs (same gates as publish_rule_composition).
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

  -- 3. Read the currently active version. There must be exactly one;
  --    no active = the rule is deactivated, bump shouldn't ressurect.
  select * into v_active
    from public.rule_versions
   where rule_id = p_rule_id and status = 'active'
   order by version desc
   limit 1
   for update;
  if not found then
    raise exception 'rule % has no active version to bump (deactivated or never published)', p_rule_id
      using errcode = '22023';
  end if;

  -- 4. Scope is preserved from the active version. Re-derive resource_type
  --    from the scope so we can re-validate trigger compatibility.
  v_scope := coalesce(v_active.compiled->'scope', jsonb_build_object('type','group'));
  v_scope_type := coalesce(v_scope->>'type', 'group');
  if v_scope_type = 'resource' then
    select resource_type into v_resource_type from public.resources where id = v_rule.resource_id;
  elsif v_scope_type = 'series' then
    select r.resource_type into v_resource_type
      from public.resources r
     where r.series_id = v_rule.series_id
     limit 1;
  end if;

  -- 5. Trigger shape + scope/resource_type compatibility (same as composer).
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
    raise exception 'trigger % does not support scope=% (rule''s preserved scope)', v_trigger_id, v_scope_type
      using errcode = '22023';
  end if;
  if v_resource_type is not null
     and v_trigger_valid_resource_types is not null
     and array_length(v_trigger_valid_resource_types, 1) > 0
     and not (v_resource_type = any (v_trigger_valid_resource_types)) then
    raise exception 'trigger % does not support resource_type=% (rule scoped to that type)', v_trigger_id, v_resource_type
      using errcode = '22023';
  end if;

  -- 6. Validate condition shapes.
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

  -- 7. Validate consequence shapes.
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

  -- 8. Compile new version. Preserve slug + scope + template_id from the
  --    active version's metadata; the bump only changes the composition.
  v_compiled := jsonb_build_object(
    'trigger',      jsonb_build_object('eventType', v_trigger_id, 'config', v_trigger_config),
    'conditions',   v_clean_conds,
    'consequences', v_clean_cons,
    'exceptions',   coalesce(v_active.compiled->'exceptions', '[]'::jsonb),
    'scope',        v_scope,
    'target',       coalesce(v_active.compiled->'target',
                             jsonb_build_object('type','ref','value','$trigger.actor')),
    'shape_ids',    jsonb_build_object(
                      'trigger',      v_trigger_id,
                      'conditions',   (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_conds) c),
                      'consequences', (select coalesce(jsonb_agg(c->>'type'), '[]'::jsonb) from jsonb_array_elements(v_clean_cons) c)
                    ),
    'slug',         v_rule.slug
  );

  -- 9. Conflict detection — same as publish, but EXCLUDE the version
  --    we're about to supersede (otherwise the bump always conflicts
  --    with itself).
  for v_against in (
    select rv.id as rv_id, r2.name as r_title
      from public.rule_versions rv
      join public.rules r2 on r2.id = rv.rule_id
     where r2.group_id = v_rule.group_id
       and rv.status   = 'active'
       and rv.id       <> v_active.id
       and rv.compiled->'trigger'->>'eventType' = v_trigger_id
       and coalesce(rv.compiled->'scope', '{}'::jsonb) = v_scope
  ) loop
    v_conflicts := v_conflicts || jsonb_build_object(
      'type',     'same_scope_overlapping',
      'severity', 'warning',
      'against_rule_version_id', v_against.rv_id,
      'against_rule_title',      v_against.r_title
    );
  end loop;

  -- 10. Supersede the old version.
  update public.rule_versions
     set status          = 'superseded',
         effective_until = now()
   where id = v_active.id;

  -- 11. Insert the new active version.
  v_new_version_no := v_active.version + 1;
  insert into public.rule_versions (
    rule_id, version, template_id, shape_params, compiled,
    status, effective_from, effective_until,
    previous_version_id, created_by, change_reason
  )
  values (
    p_rule_id, v_new_version_no,
    v_active.template_id,      -- preserve lineage
    '{}'::jsonb,
    v_compiled,
    'active', now(), null,
    v_active.id, v_uid, p_change_reason
  )
  returning id into v_new_version_id;

  -- 12. Update rules columns so the engine + readers see the new shape
  --     without joining rule_versions (engine reads from rules directly).
  update public.rules
     set name         = trim(p_name),
         trigger      = v_compiled->'trigger',
         conditions   = v_compiled->'conditions',
         consequences = v_compiled->'consequences',
         updated_at   = now()
   where id = p_rule_id;

  -- 13. Persist conflicts (warning, not blocking — caller decides).
  if jsonb_array_length(v_conflicts) > 0 then
    insert into public.rule_conflicts (group_id, rule_a_version_id, rule_b_version_id, conflict_type, severity)
    select v_rule.group_id, v_new_version_id, (c->>'against_rule_version_id')::uuid, c->>'type', c->>'severity'
      from jsonb_array_elements(v_conflicts) as c;
  end if;

  return jsonb_build_object(
    'rule_id',         p_rule_id,
    'rule_version_id', v_new_version_id,
    'version',         v_new_version_no,
    'slug',            v_rule.slug,
    'conflicts',       v_conflicts
  );
end;
$$;

revoke execute on function public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text) from public, anon;
grant  execute on function public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text) to authenticated, service_role;

comment on function public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text) is
  'Edit-in-place RPC (mig 00247). Preserves rule_id + slug + scope; supersedes the active rule_version and inserts a new one with version+1 + previous_version_id linkage. Closes §22.1 of Governance.md: edits no longer break atom continuity.';
