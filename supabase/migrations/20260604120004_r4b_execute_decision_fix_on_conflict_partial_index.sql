
-- =============================================================================
-- R.4B fix: grant_resource_right execution_kind used `on conflict on constraint
-- idx_rights_unique_active`, but that's a partial unique INDEX, not a named
-- constraint — would raise 42704 at runtime. Switch to ON CONFLICT (cols) WHERE
-- per feedback memory R.2Q-6 / postgres_on_conflict_partial_unique.
-- Only the grant_resource_right branch changes; everything else is identical
-- to the previous execute_decision body.
-- =============================================================================
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
      -- Partial unique index requires ON CONFLICT (cols) WHERE, not ON CONSTRAINT.
      insert into public.resource_rights
        (resource_id, holder_actor_id, right_kind, scope, percent,
         granted_by_actor_id, source_decision_id, starts_at, metadata)
      values
        (v_resource_id, v_holder, v_right_kind,
         v_d.payload->>'scope',
         nullif(v_d.payload->>'percent','')::numeric,
         v_caller, p_decision_id, now(),
         jsonb_build_object('granted_by_decision', p_decision_id))
      on conflict (resource_id, holder_actor_id, right_kind, coalesce(scope, ''))
        where (revoked_at is null and expired_at is null)
        do nothing
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
      null;

    else
      raise exception 'decision template % (execution_kind %) not yet implemented',
        v_d.template_key, v_template.execution_kind
        using errcode = '0A000';
    end if;
  end if;

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
