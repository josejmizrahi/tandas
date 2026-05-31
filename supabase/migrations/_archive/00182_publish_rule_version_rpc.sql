-- Mig 00171: publish_rule_version + list_rule_templates RPCs + Beta 1 template seed.
-- Builds on mig 00170 (rule_templates, rule_versions tables).
-- Doctrine: Plans/Active/Governance.md §0.5 — Templates compose shape pieces from
-- public.rule_shapes. Engine evaluates `rule_versions.compiled` (frozen snapshot).
--
-- Beta 1 templates: 5 attendance + fine variants. All use existing shape pieces.
-- No new engine code required — `rule_versions.compiled.trigger/conditions/consequences`
-- is shape-compatible with what the existing engine already evaluates.

-- =============================================================================
-- 1. list_rule_templates — iOS loads catalog at boot.
-- =============================================================================
create or replace function public.list_rule_templates()
returns setof public.rule_templates
language sql
security invoker
stable
set search_path = public
as $$
  select *
  from public.rule_templates
  where status = 'active'
  order by sort_order, display_name_es;
$$;

revoke execute on function public.list_rule_templates() from public, anon;
grant  execute on function public.list_rule_templates() to authenticated;

comment on function public.list_rule_templates() is
  'Returns the active rule template catalog for the iOS Rule Builder (gallery). Mirrors list_rule_shapes pattern (mig 00078). Read-only.';

-- =============================================================================
-- 2. publish_rule_version — create new rule from a template + params.
-- =============================================================================
-- Beta 1 contract:
--   - Caller must be group admin.
--   - p_template_id must reference an active template.
--   - p_shape_params is a flat jsonb of param values; merged over template.default_params.
--   - p_scope = {"type":"group"} | {"type":"resource","id":"<uuid>"} | {"type":"series","id":"<uuid>"}.
--   - Always creates a NEW rule (no version-bump on existing rules yet — Post-Beta).
--   - Compiles `rule_versions.compiled` jsonb (frozen snapshot) from template composition.
--   - Detects warning-level conflicts (same_scope_overlapping). Blocking conflicts deferred.
--   - Writes both public.rules (preserved engine table) AND public.rule_versions (snapshot).
--   - Returns {rule_id, rule_version_id, version, conflicts[]}.

create or replace function public.publish_rule_version(
  p_group_id      uuid,
  p_template_id   text,
  p_shape_params  jsonb default '{}'::jsonb,
  p_scope         jsonb default '{"type":"group"}'::jsonb,
  p_title         text default null,
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
  -- Auth + permission
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_group_admin(p_group_id, v_uid) then
    raise exception 'admin only' using errcode = '42501';
  end if;

  -- 1. Load + validate template
  select * into v_template from public.rule_templates where id = p_template_id;
  if not found then
    raise exception 'rule_template % not found', p_template_id using errcode = '22023';
  end if;
  if v_template.status <> 'active' then
    raise exception 'rule_template % is %', p_template_id, v_template.status using errcode = '22023';
  end if;

  -- 2. Resolve scope
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
    -- ok, no extra id
  else
    raise exception 'unsupported scope.type=%', v_scope_type using errcode = '22023';
  end if;

  -- 3. Pull composition pieces
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

  -- 4. Merge params over template defaults (user-provided wins)
  v_params := coalesce(v_template.default_params, '{}'::jsonb) || coalesce(p_shape_params, '{}'::jsonb);

  -- 5. Build compiled snapshot. Trigger/conditions/consequences are shape-compatible
  -- with the existing engine (RuleTrigger { eventType, config }, etc. — see platformTypes.ts).
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

  -- 6. Conflict detection — Beta 1 surfaces "same_scope_overlapping" as a warning.
  -- Active rule_version in same group with same trigger + same scope ⇒ overlap.
  for v_against in (
    select rv.id as rv_id, r2.title as r_title
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

  -- 7. Insert public.rules (preserved engine table; legacy columns dropped in mig 00033/00058)
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

  -- 8. Insert rule_versions snapshot (v=1, no previous)
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

  -- 9. Persist warning-level conflicts (audit; doesn't block publish for warnings)
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

revoke execute on function public.publish_rule_version(uuid, text, jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.publish_rule_version(uuid, text, jsonb, jsonb, text, text) to authenticated;

comment on function public.publish_rule_version(uuid, text, jsonb, jsonb, text, text) is
  'Publishes a new rule from a curated template + user params. Writes both public.rules (engine table, preserved) and public.rule_versions (frozen snapshot). Beta 1: admin-only, always creates new rule (no version bump). Detects same_scope_overlapping warning conflicts. Returns {rule_id, rule_version_id, version, conflicts[]}. Per Governance.md §8 + §13.';

-- =============================================================================
-- 3. Seed of the 5 Beta 1 templates (attendance + fine variants).
-- =============================================================================
-- All compose shape pieces from public.rule_shapes that already exist with
-- evaluators in supabase/functions/_shared/ruleEngine.ts. No new engine code.
--
-- TS canonical mirror: supabase/functions/_shared/ruleTemplates/v1.ts (forthcoming).
--
-- Sort order leaves gaps (10/20/30/…) for Post-Beta insertions.

insert into public.rule_templates (id, display_name_es, description_es, category, template_kind, required_capabilities, default_params, composition, status, sort_order)
values
  (
    'late_arrival_fine',
    'Multa por llegar tarde',
    'Cobra una multa cuando un miembro llega tarde a un evento (después de X minutos).',
    'attendance',
    'penalty',
    array['check_in','fines'],
    jsonb_build_object('amount', 200, 'minutes', 15),
    jsonb_build_object(
      'trigger_shape_id',      'checkInRecorded',
      'condition_shape_ids',   jsonb_build_array('checkInMinutesLate'),
      'consequence_shape_ids', jsonb_build_array('fine'),
      'scope_hint',            'series'
    ),
    'active',
    10
  ),
  (
    'no_show_fine',
    'Multa por no asistir',
    'Cobra una multa a los miembros que no hicieron check-in cuando el evento se cierra.',
    'attendance',
    'penalty',
    array['rsvp','check_in','fines'],
    jsonb_build_object('amount', 300),
    jsonb_build_object(
      'trigger_shape_id',      'eventClosed',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('fine'),
      'scope_hint',            'series'
    ),
    'active',
    20
  ),
  (
    'same_day_cancel_fine',
    'Multa por cancelar el mismo día',
    'Cobra una multa cuando un miembro cambia su RSVP a "no voy" el mismo día del evento.',
    'attendance',
    'penalty',
    array['rsvp','fines'],
    jsonb_build_object('amount', 250),
    jsonb_build_object(
      'trigger_shape_id',      'rsvpChangedSameDay',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('fine'),
      'scope_hint',            'series'
    ),
    'active',
    30
  ),
  (
    'no_rsvp_fine',
    'Multa por no responder a tiempo',
    'Cobra una multa a quien no haya respondido al RSVP antes de la fecha límite.',
    'attendance',
    'penalty',
    array['rsvp','fines'],
    jsonb_build_object('amount', 150),
    jsonb_build_object(
      'trigger_shape_id',      'rsvpDeadlinePassed',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('fine'),
      'scope_hint',            'series'
    ),
    'active',
    40
  ),
  (
    'host_no_menu_fine',
    'Multa al anfitrión si no propone menú',
    'Cobra una multa al anfitrión si no ha comunicado el plan 24h antes del evento.',
    'attendance',
    'penalty',
    array['rotating_host','fines'],
    jsonb_build_object('amount', 100, 'hours', 24),
    jsonb_build_object(
      'trigger_shape_id',      'hoursBeforeEvent',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('fine'),
      'scope_hint',            'series'
    ),
    'active',
    50
  );
