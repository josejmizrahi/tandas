
-- =============================================================================
-- R.4B · execute_decision template-aware dispatch + create_decision template_key
-- =============================================================================
-- Additive on top of existing payload-driven dispatch.
--
-- create_decision: gain optional p_template_key. If set, fetch the template,
-- inherit default_voting_model when caller did not pass one, and persist
-- decisions.template_key. iOS sigue funcionando sin tocar (signature compat).
--
-- execute_decision: if decisions.template_key is set, dispatch by template's
-- execution_kind BEFORE the existing options-payload-driven path.
--   - noop                  → no side effects
--   - archive_resource      → resources.archived_at = now()
--   - archive_rule          → rules.status = 'archived', archived_at = now()
--   - grant_resource_right  → insert into resource_rights (active)
--   - reservation_award     → fall through to existing options path
--   - other (activate_membership, set_membership_removed/_banned,
--            create_expense, mark_resource_approved, upsert_rule,
--            create_payout) → raise feature_not_supported (errcode 0A000),
--            future R.4B.x slices.
-- =============================================================================

-- create_decision (extended) ------------------------------------------------
create or replace function public.create_decision(
  p_context_actor_id uuid,
  p_decision_type    text,
  p_title            text,
  p_description      text default null,
  p_closes_at        timestamptz default null,
  p_payload          jsonb default '{}'::jsonb,
  p_client_id        text default null,
  p_voting_model     text default null,
  p_template_key     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
  v_voting_model text;
  v_template public.decision_templates_catalog%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'decisions.create') then
    raise exception 'not authorized to create decisions in context %', p_context_actor_id using errcode = '42501';
  end if;

  -- Idempotency by client_id (unchanged)
  if p_client_id is not null then
    select id into v_existing from public.decisions
     where context_actor_id = p_context_actor_id and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('decision_id', v_existing,
        'decision', (select to_jsonb(d) from public.decisions d where d.id = v_existing));
    end if;
  end if;

  -- Resolve template if provided
  if p_template_key is not null then
    select * into v_template from public.decision_templates_catalog
     where template_key = p_template_key;
    if v_template.template_key is null then
      raise exception 'unknown decision template: %', p_template_key using errcode = 'P0002';
    end if;
  end if;

  -- voting_model resolution: caller > template default > legacy auto-detect
  v_voting_model := p_voting_model;
  if v_voting_model is null and v_template.template_key is not null then
    v_voting_model := v_template.default_voting_model;
  end if;
  if v_voting_model is null then
    if coalesce(p_payload, '{}'::jsonb) ? 'options'
       and jsonb_typeof(coalesce(p_payload, '{}'::jsonb)->'options') = 'array' then
      v_voting_model := 'single_choice';
    elsif p_decision_type = 'reservation_dispute'
          and (coalesce(p_payload, '{}'::jsonb) ? 'conflict_id'
               or coalesce(p_payload, '{}'::jsonb) ? 'reservation_conflict_id') then
      v_voting_model := 'single_choice';
    else
      v_voting_model := 'yes_no_abstain';
    end if;
  end if;

  insert into public.decisions
    (context_actor_id, decision_type, title, description, created_by_actor_id, closes_at,
     payload, client_id, voting_model, template_key)
  values
    (p_context_actor_id, p_decision_type, btrim(p_title), p_description, v_caller, p_closes_at,
     coalesce(p_payload, '{}'::jsonb), p_client_id, v_voting_model, p_template_key)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'decision.created', 'decision', v_id,
    jsonb_build_object('decision_type', p_decision_type, 'title', btrim(p_title),
                       'voting_model', v_voting_model, 'template_key', p_template_key),
    p_decision_id := v_id);

  return jsonb_build_object('decision_id', v_id,
    'decision', (select to_jsonb(d) from public.decisions d where d.id = v_id));
end;
$function$;

revoke all on function public.create_decision(uuid, text, text, text, timestamptz, jsonb, text, text, text) from anon;
grant execute on function public.create_decision(uuid, text, text, text, timestamptz, jsonb, text, text, text)
  to authenticated, service_role;

-- execute_decision (extended) -----------------------------------------------
create or replace function public.execute_decision(p_decision_id uuid, p_result jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_template public.decision_templates_catalog%rowtype;
  v_winner_option text;
  v_winner_option_id uuid;
  v_opt public.decision_options%rowtype;
  v_action text;
  v_winner_res uuid;
  v_loser_res uuid;
  v_conflict_id uuid;
  v_conflict public.reservation_conflicts%rowtype;
  v_effects jsonb := '[]'::jsonb;
  -- template-driven locals
  v_resource_id uuid;
  v_rule_id uuid;
  v_holder uuid;
  v_right_kind text;
  v_right_id uuid;
  v_archived_count int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to execute decisions' using errcode = '42501';
  end if;

  if v_d.status = 'executed' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'already_executed', true);
  end if;
  if v_d.status <> 'approved' then
    raise exception 'only approved decisions can be executed (status: %)', v_d.status using errcode = '22023';
  end if;

  -- =========================================================================
  -- R.4B: template-driven dispatch (when template_key set)
  -- =========================================================================
  if v_d.template_key is not null then
    select * into v_template from public.decision_templates_catalog
     where template_key = v_d.template_key;

    if v_template.execution_kind = 'noop' then
      v_effects := jsonb_build_array(jsonb_build_object('type', 'noop'));

    elsif v_template.execution_kind = 'archive_resource' then
      v_resource_id := (v_d.payload->>'resource_id')::uuid;
      if v_resource_id is null then
        raise exception 'archive_resource template needs payload.resource_id' using errcode = '22023';
      end if;
      update public.resources
         set archived_at = now()
       where id = v_resource_id and archived_at is null;
      get diagnostics v_archived_count = row_count;
      v_effects := jsonb_build_array(jsonb_build_object(
        'type', 'resource_archived', 'resource_id', v_resource_id,
        'already_archived', v_archived_count = 0));
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'resource.archived',
        'resource', v_resource_id,
        jsonb_build_object('by_decision', p_decision_id),
        p_resource_id := v_resource_id, p_decision_id := p_decision_id);

    elsif v_template.execution_kind = 'archive_rule' then
      v_rule_id := (v_d.payload->>'rule_id')::uuid;
      if v_rule_id is null then
        raise exception 'archive_rule template needs payload.rule_id' using errcode = '22023';
      end if;
      update public.rules
         set status = 'archived', archived_at = now()
       where id = v_rule_id and status <> 'archived';
      v_effects := jsonb_build_array(jsonb_build_object(
        'type', 'rule_archived', 'rule_id', v_rule_id));
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'rule.archived',
        'rule', v_rule_id,
        jsonb_build_object('by_decision', p_decision_id),
        p_decision_id := p_decision_id);

    elsif v_template.execution_kind = 'grant_resource_right' then
      v_resource_id := (v_d.payload->>'resource_id')::uuid;
      v_holder      := (v_d.payload->>'holder_actor_id')::uuid;
      v_right_kind  := v_d.payload->>'right_kind';
      if v_resource_id is null or v_holder is null or v_right_kind is null then
        raise exception 'grant_resource_right template needs payload.resource_id, holder_actor_id, right_kind'
          using errcode = '22023';
      end if;
      insert into public.resource_rights
        (resource_id, holder_actor_id, right_kind, scope, percent,
         granted_by_actor_id, source_decision_id, starts_at, metadata)
      values
        (v_resource_id, v_holder, v_right_kind,
         v_d.payload->>'scope',
         nullif(v_d.payload->>'percent','')::numeric,
         v_caller, p_decision_id, now(),
         jsonb_build_object('granted_by_decision', p_decision_id))
      on conflict on constraint idx_rights_unique_active do nothing
      returning id into v_right_id;

      v_effects := jsonb_build_array(jsonb_build_object(
        'type', 'right_granted',
        'resource_id', v_resource_id,
        'holder_actor_id', v_holder,
        'right_kind', v_right_kind,
        'right_id', v_right_id));
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'resource.right_granted',
        'resource_right', v_right_id,
        jsonb_build_object('by_decision', p_decision_id, 'right_kind', v_right_kind),
        p_resource_id := v_resource_id, p_decision_id := p_decision_id);

    elsif v_template.execution_kind = 'reservation_award' then
      -- Delegate to existing options-payload-driven path (below).
      null;

    else
      -- Known templates whose execution is not yet wired in this slice.
      raise exception 'decision template % (execution_kind %) not yet implemented',
        v_d.template_key, v_template.execution_kind
        using errcode = '0A000';
    end if;
  end if;

  -- =========================================================================
  -- Existing payload-driven dispatch (R.2Q) — runs when v_effects still empty
  -- =========================================================================
  v_winner_option := v_d.result->>'winning_option';
  v_winner_option_id := (v_d.result->>'winning_option_id')::uuid;

  if v_winner_option_id is null and v_winner_option is not null then
    select id into v_winner_option_id from public.decision_options
     where decision_id = p_decision_id and option_key = v_winner_option;
  end if;

  if v_effects = '[]'::jsonb and v_winner_option_id is not null then
    select * into v_opt from public.decision_options where id = v_winner_option_id;
    v_action := v_opt.payload->>'action';

    if v_action = 'reservation_award' then
      v_winner_res := (v_opt.payload->>'winner_reservation_id')::uuid;
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        v_loser_res := case when v_winner_res = v_conflict.reservation_a_id
                            then v_conflict.reservation_b_id else v_conflict.reservation_a_id end;
        update public.resource_reservations
           set status = 'rejected', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('rejected_by_decision', p_decision_id)
         where id = v_loser_res and status in ('requested', 'approved');
        update public.resource_reservations
           set status = 'approved', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('approved_by_decision', p_decision_id)
         where id = v_winner_res and status = 'requested';
        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id,
                                                         'winner_reservation_id', v_winner_res)
         where id = v_conflict.id;
        perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.approved',
          'reservation', v_winner_res,
          jsonb_build_object('by_decision', p_decision_id, 'winning_option', v_winner_option),
          p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);
        perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.rejected',
          'reservation', v_loser_res,
          jsonb_build_object('by_decision', p_decision_id),
          p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);
        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id),
          jsonb_build_object('type', 'reservation_approved', 'reservation_id', v_winner_res),
          jsonb_build_object('type', 'reservation_rejected', 'reservation_id', v_loser_res));
      end if;

    elsif v_action = 'split_reservation' then
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        update public.resource_reservations
           set status = 'approved', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('split_by_decision', p_decision_id)
         where id in (v_conflict.reservation_a_id, v_conflict.reservation_b_id)
           and status = 'requested';
        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id, 'resolution', 'split')
         where id = v_conflict.id;
        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id, 'resolution', 'split'));
      end if;

    elsif v_action = 'cancel_reservations' then
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        update public.resource_reservations
           set status = 'cancelled', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('cancelled_by_decision', p_decision_id)
         where id in (v_conflict.reservation_a_id, v_conflict.reservation_b_id)
           and status in ('requested', 'approved');
        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id, 'resolution', 'cancelled')
         where id = v_conflict.id;
        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id, 'resolution', 'cancelled'));
      end if;
    end if;
  end if;

  -- Legacy fallback (R.2G): reservation_dispute with payload-level option_reservations
  if v_effects = '[]'::jsonb
     and v_d.decision_type = 'reservation_dispute'
     and v_d.payload ? 'reservation_conflict_id'
     and v_winner_option is not null
     and v_d.payload ? 'option_reservations'
     and v_d.payload->'option_reservations' ? v_winner_option then
    select * into v_conflict from public.reservation_conflicts
     where id = (v_d.payload->>'reservation_conflict_id')::uuid for update;
    if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
      v_winner_res := (v_d.payload->'option_reservations'->>v_winner_option)::uuid;
      v_loser_res := case when v_winner_res = v_conflict.reservation_a_id
                          then v_conflict.reservation_b_id else v_conflict.reservation_a_id end;
      update public.resource_reservations
         set status = 'rejected', source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('rejected_by_decision', p_decision_id)
       where id = v_loser_res and status in ('requested', 'approved');
      update public.resource_reservations
         set status = 'approved', source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('approved_by_decision', p_decision_id)
       where id = v_winner_res and status = 'requested';
      update public.reservation_conflicts
         set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id, 'winner_reservation_id', v_winner_res)
       where id = v_conflict.id;
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.approved',
        'reservation', v_winner_res,
        jsonb_build_object('by_decision', p_decision_id, 'winning_option', v_winner_option),
        p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.rejected',
        'reservation', v_loser_res,
        jsonb_build_object('by_decision', p_decision_id),
        p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);
      v_effects := jsonb_build_array(
        jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id),
        jsonb_build_object('type', 'reservation_approved', 'reservation_id', v_winner_res),
        jsonb_build_object('type', 'reservation_rejected', 'reservation_id', v_loser_res));
    end if;
  end if;

  update public.decisions
     set status = 'executed', executed_at = now(),
         result = result || coalesce(p_result, '{}'::jsonb)
                  || jsonb_build_object('executed_by_actor_id', v_caller, 'effects', v_effects)
   where id = p_decision_id;

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.executed', 'decision', p_decision_id,
    jsonb_build_object('effects', v_effects, 'template_key', v_d.template_key), p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'effects', v_effects);
end;
$function$;

revoke all on function public.execute_decision(uuid, jsonb) from anon;
grant execute on function public.execute_decision(uuid, jsonb) to authenticated, service_role;
