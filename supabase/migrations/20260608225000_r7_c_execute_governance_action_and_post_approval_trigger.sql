-- R.7.C — Governance Orchestration: execute_governance_action PUSH + post-approval trigger
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md §4 (camino A firmado)
-- Cambio vs plan: TRIGGER en governance_actions (no extension de close_decision).
--   close_decision ya update governance_actions.status='approved' (R.5 line existente).
--   Trigger AFTER UPDATE intercepta y auto-invoca execute_governance_action si push_supported=true.
--   Preserva close_decision intacto (R.5 untouched).
-- DoD: 4 dispatch paths (assign_role/archive_resource/record_fine/create_rule) +
--      idempotency por status + best-effort no rompe close_decision.

-- §1 — Internal dispatch helper (CASE por execution_rpc)
create or replace function public._governance_action_dispatch(
  p_row public.governance_actions,
  p_catalog public.governance_action_catalog
) returns jsonb
language plpgsql security definer set search_path to public, auth as $$
declare
  v_result jsonb;
  v_role_key text;
begin
  case p_catalog.execution_rpc
    when 'assign_role' then
      v_role_key := coalesce(p_row.payload->>'role_key', p_catalog.metadata->>'role_key');
      if v_role_key is null then
        raise exception 'assign_role dispatch: role_key missing in payload and catalog metadata';
      end if;
      perform public.assign_role(p_row.context_actor_id, p_row.target_id, v_role_key);
      v_result := jsonb_build_object(
        'execution_rpc','assign_role',
        'target_id', p_row.target_id,
        'role_key', v_role_key
      );

    when 'archive_resource' then
      if p_row.target_id is null then
        raise exception 'archive_resource dispatch: target_id required';
      end if;
      perform public.archive_resource(p_row.target_id);
      v_result := jsonb_build_object(
        'execution_rpc','archive_resource',
        'resource_id', p_row.target_id
      );

    when 'record_fine' then
      if p_row.target_id is null then
        raise exception 'record_fine dispatch: target_id (debtor) required';
      end if;
      if p_row.payload->>'amount' is null or p_row.payload->>'currency' is null then
        raise exception 'record_fine dispatch: payload.amount + payload.currency required';
      end if;
      perform public.record_fine(
        p_row.context_actor_id,
        p_row.target_id,
        (p_row.payload->>'amount')::numeric,
        p_row.payload->>'currency',
        p_row.payload->>'reason'
      );
      v_result := jsonb_build_object(
        'execution_rpc','record_fine',
        'debtor_actor_id', p_row.target_id,
        'amount', (p_row.payload->>'amount')::numeric,
        'currency', p_row.payload->>'currency'
      );

    when 'create_rule' then
      if p_row.payload->>'title' is null then
        raise exception 'create_rule dispatch: payload.title required';
      end if;
      v_result := public.create_rule(
        p_row.context_actor_id,
        p_row.payload->>'title',
        p_row.payload->>'trigger_event_type',
        nullif(p_row.payload->'condition_tree','null')::jsonb,
        nullif(p_row.payload->'consequences','null')::jsonb,
        p_row.payload->>'body',
        coalesce(p_row.payload->>'rule_type','automation'),
        coalesce((p_row.payload->>'severity')::int, 1)
      );

    else
      raise exception 'execute_governance_action: execution_rpc % not supported in R.7.C dispatch',
        p_catalog.execution_rpc using errcode = 'P0001';
  end case;

  return v_result;
end;
$$;

-- §2 — execute_governance_action (PUSH executor, never raises — returns jsonb status)
create or replace function public.execute_governance_action(
  p_governance_action_id uuid
) returns jsonb
language plpgsql security definer set search_path to public, auth as $$
declare
  v_row public.governance_actions%rowtype;
  v_catalog public.governance_action_catalog%rowtype;
  v_canonical_key text;
  v_result jsonb;
  v_caller uuid := public.current_actor_id();
  v_err text;
begin
  select * into v_row from public.governance_actions where id = p_governance_action_id for update;
  if v_row.id is null then
    return jsonb_build_object('governance_action_id', p_governance_action_id, 'status','not_found');
  end if;

  -- Idempotency: status='executed' → noop
  if v_row.status = 'executed' then
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','executed', 'noop', true, 'idempotent_replay', true
    );
  end if;

  -- Solo aprobados son ejecutables (not_required no entra PUSH path)
  if v_row.status <> 'approved' then
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status', v_row.status, 'noop', true,
      'reason', 'status_not_approved'
    );
  end if;

  v_canonical_key := public._governance_action_resolve(v_row.action_key);
  select * into v_catalog from public.governance_action_catalog where action_key = v_canonical_key;

  if v_catalog.action_key is null then
    update public.governance_actions
       set status='failed',
           error_message=format('action_key %s not in catalog', v_canonical_key)
     where id = p_governance_action_id;
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','failed','reason','catalog_missing'
    );
  end if;

  if not v_catalog.push_supported then
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status', v_row.status, 'noop', true,
      'reason', 'pull_only', 'push_supported', false
    );
  end if;

  if v_catalog.execution_rpc is null then
    update public.governance_actions
       set status='failed',
           error_message='catalog.execution_rpc is null'
     where id = p_governance_action_id;
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','failed','reason','execution_rpc_missing'
    );
  end if;

  -- Dispatch con error handling (NO re-raise: returns jsonb status para que trigger no rollback close_decision)
  begin
    v_result := public._governance_action_dispatch(v_row, v_catalog);

    update public.governance_actions
       set status='executed',
           executed_at = now(),
           executed_by_actor_id = v_caller,
           result = v_result
     where id = p_governance_action_id;

    perform public._emit_activity(
      v_row.context_actor_id, v_caller, 'governance.executed',
      'governance_action', p_governance_action_id,
      jsonb_build_object('action_key', v_canonical_key, 'result', v_result),
      p_decision_id := v_row.decision_id
    );

    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','executed',
      'result', v_result
    );

  exception when others then
    v_err := SQLERRM;
    update public.governance_actions
       set status='failed',
           error_message = v_err
     where id = p_governance_action_id;

    perform public._emit_activity(
      v_row.context_actor_id, v_caller, 'governance.failed',
      'governance_action', p_governance_action_id,
      jsonb_build_object('action_key', v_canonical_key, 'error', v_err),
      p_decision_id := v_row.decision_id
    );

    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','failed',
      'error', v_err
    );
  end;
end;
$$;

grant execute on function public.execute_governance_action(uuid) to authenticated;

comment on function public.execute_governance_action(uuid) is
  'R.7.C — PUSH executor. Idempotent por status (executed -> noop). Solo ejecuta si status=approved AND catalog.push_supported=true AND catalog.execution_rpc set. Dispatch CASE on execution_rpc para 4 RPCs (assign_role/archive_resource/record_fine/create_rule). NEVER raises — returns jsonb status para que el trigger AFTER UPDATE no rompa close_decision.';

-- §3 — Trigger AFTER UPDATE on governance_actions when status transitions to 'approved'
create or replace function public._governance_action_post_approval()
returns trigger language plpgsql security definer set search_path to public, auth as $$
declare
  v_canonical_key text;
  v_catalog public.governance_action_catalog%rowtype;
  v_exec_result jsonb;
begin
  if NEW.status <> 'approved' or OLD.status = 'approved' then
    return NEW;
  end if;

  v_canonical_key := public._governance_action_resolve(NEW.action_key);
  select * into v_catalog from public.governance_action_catalog where action_key = v_canonical_key;

  perform public._emit_activity(
    NEW.context_actor_id,
    coalesce(NEW.proposed_by_actor_id, NEW.context_actor_id),
    'governance.approved',
    'governance_action',
    NEW.id,
    jsonb_build_object(
      'action_key', v_canonical_key,
      'push_supported', coalesce(v_catalog.push_supported, false)
    ),
    p_decision_id := NEW.decision_id
  );

  if v_catalog.action_key is not null and v_catalog.push_supported then
    v_exec_result := public.execute_governance_action(NEW.id);
  end if;

  return NEW;
end;
$$;

drop trigger if exists governance_action_post_approval on public.governance_actions;
create trigger governance_action_post_approval
  after update of status on public.governance_actions
  for each row execute function public._governance_action_post_approval();

comment on function public._governance_action_post_approval() is
  'R.7.C — Trigger AFTER UPDATE on governance_actions.status. Intercepta transicion a approved (close_decision o cualquier path). Emite governance.approved. Auto-invoca execute_governance_action si catalog.push_supported=true. execute_governance_action never raises -> trigger no rompe close_decision en errores.';
