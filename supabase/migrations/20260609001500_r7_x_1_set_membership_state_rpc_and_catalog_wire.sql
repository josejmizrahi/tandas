-- R.7.x.1 — set_membership_state RPC + catalog wire + dispatch extension
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md (R.7.x backlog firmado)
-- Founder order R.7.x: (1) set_membership_state → (2) transfer_resource_ownership →
-- (3) archive_rule → (4) forgive_obligation. Empezamos por #1.
--
-- Desbloquea PUSH para member.pause (catalog row currently push_supported=false +
-- execution_rpc=null TBD) y member.ban (catalog row alias-only TBD). Después de
-- aprobar la decision via close_decision → trigger AFTER UPDATE → execute_governance_action
-- → dispatch CASE 'set_membership_state' → set_membership_state(target, target_state).
-- Para callers directos (no via governance): PULL gate via governance_policy +
-- _governance_action_approved (mismo pattern que remove_member).

-- §1 — set_membership_state(p_context_actor_id, p_member_actor_id, p_target_state, p_reason?)
create or replace function public.set_membership_state(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_target_state text,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_current_state text;
  v_policy_key text;
  v_action_key text;
  v_ga uuid;
  v_governance_required boolean := false;
  v_pol jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'not authorized to change member state' using errcode = '42501';
  end if;
  if p_member_actor_id = v_caller then
    raise exception 'use leave_context to change your own state' using errcode = '22023';
  end if;
  if p_target_state not in ('active', 'paused', 'banned') then
    raise exception 'invalid target_state: %, must be active / paused / banned', p_target_state
      using errcode = '22023';
  end if;

  -- Map target_state → governance policy/action keys
  case p_target_state
    when 'paused' then v_policy_key := 'member_pause_requires_vote'; v_action_key := 'member.pause';
    when 'banned' then v_policy_key := 'member_ban_requires_vote';   v_action_key := 'member.ban';
    when 'active' then v_policy_key := null;                          v_action_key := null;
  end case;

  -- PULL gate: si target requiere voto, buscar approval
  if v_action_key is not null then
    v_pol := public.governance_policy(p_context_actor_id, v_policy_key);
    if v_pol = 'true'::jsonb or v_pol is null then
      v_governance_required := true;
    end if;
  end if;

  if v_governance_required then
    v_ga := public._governance_action_approved(p_context_actor_id, v_action_key, p_member_actor_id);
    if v_ga is null then
      raise exception 'governance_required: state change to % requires an approved decision in this context', p_target_state
        using errcode = '42501',
        hint = 'call request_governance_action(context, ''' || v_action_key || ''', ''actor'', member_id) and get it approved first';
    end if;
  end if;

  -- Verify member exists + capture current state
  select membership_status into v_current_state
  from public.actor_memberships
  where context_actor_id = p_context_actor_id
    and member_actor_id = p_member_actor_id;
  if v_current_state is null then
    raise exception 'member not found in context' using errcode = 'P0002';
  end if;

  -- No-op si ya está en el estado target (idempotent)
  if v_current_state = p_target_state then
    return jsonb_build_object('changed', false, 'state', p_target_state, 'noop', true);
  end if;

  -- Apply state transition
  update public.actor_memberships
     set membership_status = p_target_state,
         metadata = metadata || jsonb_strip_nulls(jsonb_build_object(
           'state_changed_by', v_caller,
           'state_changed_at', now(),
           'state_changed_from', v_current_state,
           'state_changed_reason', p_reason
         ))
   where context_actor_id = p_context_actor_id
     and member_actor_id = p_member_actor_id;

  -- Mark governance action executed si aplica
  if v_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_ga;
  end if;

  -- Emit activity con event_type específico por estado
  perform public._emit_activity(
    p_context_actor_id, v_caller,
    case p_target_state
      when 'paused' then 'member.paused'
      when 'banned' then 'member.banned'
      when 'active' then 'member.reactivated'
    end,
    'actor', p_member_actor_id,
    jsonb_strip_nulls(jsonb_build_object(
      'from_state', v_current_state,
      'to_state', p_target_state,
      'reason', p_reason,
      'governance_action_id', v_ga
    ))
  );

  return jsonb_build_object(
    'changed', true,
    'state', p_target_state,
    'previous_state', v_current_state,
    'governance_action_id', v_ga
  );
end;
$$;

grant execute on function public.set_membership_state(uuid, uuid, text, text) to authenticated;

comment on function public.set_membership_state(uuid, uuid, text, text) is
  'R.7.x.1 — Canonical RPC para transicionar membership_status entre active/paused/banned.
PULL gate: si governance_policy=true (o catalog default_requires_decision=true sin policy
override false), requiere governance_action approval via _governance_action_approved.
Target=active no requiere governance (reactivate es protective revert). Self protection:
use leave_context. Idempotent: no-op si already en target state. Emits member.paused /
member.banned / member.reactivated activity types.';

-- §2 — Extender _governance_action_dispatch para handle execution_rpc='set_membership_state'
create or replace function public._governance_action_dispatch(
  p_row public.governance_actions,
  p_catalog public.governance_action_catalog
) returns jsonb
language plpgsql security definer set search_path to public, auth
as $$
declare
  v_result jsonb;
  v_role_key text;
  v_target_state text;
begin
  case p_catalog.execution_rpc
    when 'assign_role' then
      v_role_key := coalesce(p_row.payload->>'role_key', p_catalog.metadata->>'role_key');
      if v_role_key is null then
        raise exception 'assign_role dispatch: role_key missing in payload and catalog metadata';
      end if;
      perform public.assign_role(p_row.context_actor_id, p_row.target_id, v_role_key);
      v_result := jsonb_build_object('execution_rpc','assign_role','target_id', p_row.target_id, 'role_key', v_role_key);

    when 'archive_resource' then
      if p_row.target_id is null then
        raise exception 'archive_resource dispatch: target_id required';
      end if;
      perform public.archive_resource(p_row.target_id);
      v_result := jsonb_build_object('execution_rpc','archive_resource','resource_id', p_row.target_id);

    when 'record_fine' then
      if p_row.target_id is null then
        raise exception 'record_fine dispatch: target_id (debtor) required';
      end if;
      if p_row.payload->>'amount' is null or p_row.payload->>'currency' is null then
        raise exception 'record_fine dispatch: payload.amount + payload.currency required';
      end if;
      perform public.record_fine(
        p_row.context_actor_id, p_row.target_id,
        (p_row.payload->>'amount')::numeric,
        p_row.payload->>'currency',
        p_row.payload->>'reason'
      );
      v_result := jsonb_build_object('execution_rpc','record_fine','debtor_actor_id', p_row.target_id,
        'amount', (p_row.payload->>'amount')::numeric, 'currency', p_row.payload->>'currency');

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

    when 'set_membership_state' then
      if p_row.target_id is null then
        raise exception 'set_membership_state dispatch: target_id (member) required';
      end if;
      v_target_state := coalesce(p_row.payload->>'target_state', p_catalog.metadata->>'target_state');
      if v_target_state is null then
        raise exception 'set_membership_state dispatch: target_state missing in payload and catalog metadata';
      end if;
      perform public.set_membership_state(
        p_row.context_actor_id, p_row.target_id, v_target_state,
        p_row.payload->>'reason'
      );
      v_result := jsonb_build_object('execution_rpc','set_membership_state',
        'target_id', p_row.target_id, 'target_state', v_target_state);

    else
      raise exception 'execute_governance_action: execution_rpc % not supported in R.7 dispatch',
        p_catalog.execution_rpc using errcode = 'P0001';
  end case;

  return v_result;
end;
$$;

-- §3 — Catalog wire: member.pause + member.ban gain execution_rpc + push_supported=true
update public.governance_action_catalog
   set execution_rpc = 'set_membership_state',
       push_supported = true,
       metadata = metadata || jsonb_build_object('target_state', 'paused'),
       updated_at = now()
 where action_key = 'member.pause';

update public.governance_action_catalog
   set execution_rpc = 'set_membership_state',
       push_supported = true,
       metadata = metadata || jsonb_build_object('target_state', 'banned'),
       updated_at = now()
 where action_key = 'member.ban';
