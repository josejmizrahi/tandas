-- R.7.x.3 — archive_rule RPC + dispatch wire + catalog flip
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md (R.7.x #3/4)
-- Doctrine R.7 PULL gate consistent con set_membership_state + transfer_resource_ownership.

-- §1 archive_rule(p_rule_id, p_reason?)
create or replace function public.archive_rule(
  p_rule_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_rule public.rules%rowtype;
  v_ga uuid;
  v_via_governance boolean;
  v_pol jsonb;
  v_catalog_default boolean;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_rule from public.rules where id = p_rule_id;
  if v_rule.id is null then raise exception 'rule not found' using errcode = 'P0002'; end if;

  if not public.has_actor_authority(v_rule.context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to archive rules in context %', v_rule.context_actor_id using errcode = '42501';
  end if;

  -- Idempotent: ya archived → no-op
  if v_rule.status = 'archived' then
    return jsonb_build_object('changed', false, 'archived', true, 'noop', true);
  end if;

  -- Check governance approval first (auto-detect path)
  v_ga := public._governance_action_approved(v_rule.context_actor_id, 'rule.archive', p_rule_id);
  v_via_governance := (v_ga is not null);

  if not v_via_governance then
    -- Direct path: PULL gate doctrine R.7
    v_pol := public.governance_policy(v_rule.context_actor_id, 'rule_change_requires_vote');
    select default_requires_decision into v_catalog_default
      from public.governance_action_catalog where action_key = 'rule.archive';
    if v_pol = 'true'::jsonb or (v_pol is null and coalesce(v_catalog_default, false)) then
      raise exception 'governance_required: rule.archive requires an approved decision in this context'
        using errcode = '42501',
        hint = 'call request_governance_action(context, ''rule.archive'', ''rule'', rule_id) and get it approved first';
    end if;
  end if;

  -- Apply archive
  update public.rules
     set status = 'archived',
         archived_at = now(),
         updated_at = now()
   where id = p_rule_id;

  -- Mark governance action executed si aplica
  if v_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_ga;
  end if;

  -- Activity
  perform public._emit_activity(
    v_rule.context_actor_id, v_caller,
    'rule.archived', 'rule', p_rule_id,
    jsonb_strip_nulls(jsonb_build_object(
      'rule_title', v_rule.title,
      'rule_type', v_rule.rule_type,
      'severity', v_rule.severity,
      'reason', p_reason,
      'via_governance', v_via_governance,
      'governance_action_id', v_ga
    ))
  );

  return jsonb_build_object(
    'changed', true,
    'rule_id', p_rule_id,
    'status', 'archived',
    'via_governance', v_via_governance,
    'governance_action_id', v_ga
  );
end;
$$;

grant execute on function public.archive_rule(uuid, text) to authenticated;

comment on function public.archive_rule(uuid, text) is
  'R.7.x.3 — Soft archive de una regla. Marca status=archived + archived_at=now().
PULL gate doctrine R.7: policy=true OR (null+catalog default) → require governance approval.
Auto-detect: si _governance_action_approved encuentra row → bypass policy check (PUSH path).
Idempotent: no-op si already archived. Emits rule.archived activity con metadata enriched.';

-- §2 dispatch CASE extension
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

    when 'transfer_resource_ownership' then
      if p_row.target_id is null then
        raise exception 'transfer_resource_ownership dispatch: target_id (resource) required';
      end if;
      if p_row.payload->>'to_actor_id' is null then
        raise exception 'transfer_resource_ownership dispatch: payload.to_actor_id required';
      end if;
      if not exists (select 1 from public.actors where id = (p_row.payload->>'to_actor_id')::uuid) then
        raise exception 'transfer_resource_ownership dispatch: to_actor_id % not found in actors',
          p_row.payload->>'to_actor_id' using errcode = 'P0002';
      end if;
      perform public.transfer_resource_ownership(
        p_row.target_id,
        (p_row.payload->>'to_actor_id')::uuid,
        p_row.payload->>'reason'
      );
      v_result := jsonb_build_object('execution_rpc','transfer_resource_ownership',
        'resource_id', p_row.target_id,
        'to_actor_id', p_row.payload->>'to_actor_id');

    when 'archive_rule' then
      if p_row.target_id is null then
        raise exception 'archive_rule dispatch: target_id (rule) required';
      end if;
      perform public.archive_rule(p_row.target_id, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','archive_rule','rule_id', p_row.target_id);

    else
      raise exception 'execute_governance_action: execution_rpc % not supported in R.7 dispatch',
        p_catalog.execution_rpc using errcode = 'P0001';
  end case;

  return v_result;
end;
$$;

-- §3 catalog flip rule.archive
update public.governance_action_catalog
   set execution_rpc = 'archive_rule',
       push_supported = true,
       updated_at = now()
 where action_key = 'rule.archive';
