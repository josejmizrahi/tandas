-- R.7.x.4 — forgive_obligation RPC + dispatch wire + catalog (fine.forgive + obligation.forgive)
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md (R.7.x #4/4 — final)
-- Founder mandate: status nuevo 'forgiven' (CHECK ya lo incluye), NO contaminar ledger
-- como 'paid'. Emit obligation.forgiven activity. Marcar fine.forgive + agregar
-- obligation.forgive al catalog (founder R.7.x.4 firmado).

-- §1 forgive_obligation(p_obligation_id, p_reason?)
create or replace function public.forgive_obligation(
  p_obligation_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
  v_ga uuid;
  v_via_governance boolean;
  v_pol jsonb;
  v_catalog_default boolean;
  v_is_creditor boolean;
  v_is_manager boolean;
  v_action_key text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  if v_ob.status = 'forgiven' then
    return jsonb_build_object('changed', false, 'status', 'forgiven', 'noop', true);
  end if;

  if v_ob.status not in ('open', 'accepted', 'in_progress') then
    raise exception 'cannot forgive obligation in status %', v_ob.status using errcode = '22023';
  end if;

  v_is_creditor := (v_ob.creditor_actor_id = v_caller);
  v_is_manager := v_ob.context_actor_id is not null
              and public.has_actor_authority(v_ob.context_actor_id, v_caller, 'money.settle');

  if not (v_is_creditor or v_is_manager) then
    raise exception 'not authorized to forgive this obligation (must be creditor or money.settle admin)'
      using errcode = '42501';
  end if;

  v_action_key := case when v_ob.obligation_type = 'fine' then 'fine.forgive' else 'obligation.forgive' end;

  if v_ob.context_actor_id is not null then
    v_ga := public._governance_action_approved(v_ob.context_actor_id, v_action_key, p_obligation_id);
    if v_ga is null and v_action_key = 'fine.forgive' then
      v_ga := public._governance_action_approved(v_ob.context_actor_id, 'obligation.forgive', p_obligation_id);
    end if;
  end if;
  v_via_governance := (v_ga is not null);

  if not v_via_governance and v_ob.context_actor_id is not null then
    declare v_pol_key text := case when v_ob.obligation_type = 'fine' then 'fine_forgive_requires_vote' else 'obligation_forgive_requires_vote' end;
    begin
      v_pol := public.governance_policy(v_ob.context_actor_id, v_pol_key);
    end;
    select default_requires_decision into v_catalog_default
      from public.governance_action_catalog where action_key = v_action_key;
    if v_pol = 'true'::jsonb or (v_pol is null and coalesce(v_catalog_default, false)) then
      raise exception 'governance_required: forgiving this obligation requires an approved decision in this context'
        using errcode = '42501',
        hint = 'call request_governance_action(context, ''' || v_action_key || ''', ''obligation'', obligation_id) and get it approved first';
    end if;
  end if;

  update public.obligations
     set status = 'forgiven',
         updated_at = now(),
         metadata = metadata || jsonb_strip_nulls(jsonb_build_object(
           'forgiven_by', v_caller,
           'forgiven_at', now(),
           'forgive_reason', p_reason,
           'via_governance', v_via_governance,
           'governance_action_id', v_ga,
           'previous_status', v_ob.status
         ))
   where id = p_obligation_id;

  if v_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_ga;
  end if;

  perform public._emit_activity(
    coalesce(v_ob.context_actor_id, v_ob.creditor_actor_id),
    v_caller,
    'obligation.forgiven', 'obligation', p_obligation_id,
    jsonb_strip_nulls(jsonb_build_object(
      'obligation_type', v_ob.obligation_type,
      'obligation_kind', v_ob.obligation_kind,
      'amount', v_ob.amount,
      'currency', v_ob.currency,
      'debtor', v_ob.debtor_actor_id,
      'creditor', v_ob.creditor_actor_id,
      'reason', p_reason,
      'via_governance', v_via_governance,
      'governance_action_id', v_ga,
      'previous_status', v_ob.status
    ))
  );

  return jsonb_build_object(
    'changed', true,
    'obligation_id', p_obligation_id,
    'status', 'forgiven',
    'via_governance', v_via_governance,
    'governance_action_id', v_ga
  );
end;
$$;

grant execute on function public.forgive_obligation(uuid, text) to authenticated;

comment on function public.forgive_obligation(uuid, text) is
  'R.7.x.4 — Condona obligación marcando status=forgiven (NO contamina ledger como paid).
Auth: creditor OR money.settle admin. Solo aplica a active obligations (open/accepted/
in_progress). PULL gate doctrine R.7: policy=true OR null+catalog default → require
governance. Auto-detect _governance_action_approved (fine.forgive primero si type=fine,
sino obligation.forgive). Idempotent: no-op si already forgiven. Emits obligation.forgiven
activity con full metadata audit trail.';

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
      if p_row.target_id is null then raise exception 'archive_resource dispatch: target_id required'; end if;
      perform public.archive_resource(p_row.target_id);
      v_result := jsonb_build_object('execution_rpc','archive_resource','resource_id', p_row.target_id);

    when 'record_fine' then
      if p_row.target_id is null then raise exception 'record_fine dispatch: target_id (debtor) required'; end if;
      if p_row.payload->>'amount' is null or p_row.payload->>'currency' is null then
        raise exception 'record_fine dispatch: payload.amount + payload.currency required';
      end if;
      perform public.record_fine(p_row.context_actor_id, p_row.target_id,
        (p_row.payload->>'amount')::numeric, p_row.payload->>'currency', p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','record_fine','debtor_actor_id', p_row.target_id,
        'amount', (p_row.payload->>'amount')::numeric, 'currency', p_row.payload->>'currency');

    when 'create_rule' then
      if p_row.payload->>'title' is null then raise exception 'create_rule dispatch: payload.title required'; end if;
      v_result := public.create_rule(p_row.context_actor_id, p_row.payload->>'title',
        p_row.payload->>'trigger_event_type',
        nullif(p_row.payload->'condition_tree','null')::jsonb,
        nullif(p_row.payload->'consequences','null')::jsonb,
        p_row.payload->>'body', coalesce(p_row.payload->>'rule_type','automation'),
        coalesce((p_row.payload->>'severity')::int, 1));

    when 'set_membership_state' then
      if p_row.target_id is null then raise exception 'set_membership_state dispatch: target_id (member) required'; end if;
      v_target_state := coalesce(p_row.payload->>'target_state', p_catalog.metadata->>'target_state');
      if v_target_state is null then
        raise exception 'set_membership_state dispatch: target_state missing in payload and catalog metadata';
      end if;
      perform public.set_membership_state(p_row.context_actor_id, p_row.target_id, v_target_state, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','set_membership_state',
        'target_id', p_row.target_id, 'target_state', v_target_state);

    when 'transfer_resource_ownership' then
      if p_row.target_id is null then raise exception 'transfer_resource_ownership dispatch: target_id (resource) required'; end if;
      if p_row.payload->>'to_actor_id' is null then
        raise exception 'transfer_resource_ownership dispatch: payload.to_actor_id required';
      end if;
      if not exists (select 1 from public.actors where id = (p_row.payload->>'to_actor_id')::uuid) then
        raise exception 'transfer_resource_ownership dispatch: to_actor_id % not found in actors',
          p_row.payload->>'to_actor_id' using errcode = 'P0002';
      end if;
      perform public.transfer_resource_ownership(p_row.target_id,
        (p_row.payload->>'to_actor_id')::uuid, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','transfer_resource_ownership',
        'resource_id', p_row.target_id, 'to_actor_id', p_row.payload->>'to_actor_id');

    when 'archive_rule' then
      if p_row.target_id is null then raise exception 'archive_rule dispatch: target_id (rule) required'; end if;
      perform public.archive_rule(p_row.target_id, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','archive_rule','rule_id', p_row.target_id);

    when 'forgive_obligation' then
      if p_row.target_id is null then
        raise exception 'forgive_obligation dispatch: target_id (obligation) required';
      end if;
      perform public.forgive_obligation(p_row.target_id, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','forgive_obligation','obligation_id', p_row.target_id);

    else
      raise exception 'execute_governance_action: execution_rpc % not supported in R.7 dispatch',
        p_catalog.execution_rpc using errcode = 'P0001';
  end case;

  return v_result;
end;
$$;

-- §3 catalog: INSERT/UPSERT obligation.forgive (general) + fine.forgive (subset semántico)
insert into public.governance_action_catalog (
  action_key, display_name, domain, default_requires_decision,
  policy_key, execution_rpc, push_supported, dangerous,
  legacy_aliases, metadata
) values
  ('obligation.forgive',
   'Condonar compromiso',
   'money',
   true,
   'obligation_forgive_requires_vote',
   'forgive_obligation',
   true,
   false,
   array[]::text[],
   jsonb_build_object(
     'description', 'Condona cualquier obligación (kind money o action). Marca status=forgiven sin contaminar ledger como paid.',
     'r7_notes', 'R.7.x.4 shipped. Forgiven es estado terminal pero auditable; reason guardado en metadata.'
   )),
  ('fine.forgive',
   'Condonar multa',
   'money',
   true,
   'fine_forgive_requires_vote',
   'forgive_obligation',
   true,
   false,
   array[]::text[],
   jsonb_build_object(
     'description', 'Condona una multa específicamente (obligation_type=fine). Subset semántico de obligation.forgive.',
     'r7_notes', 'R.7.x.4 shipped. Si type ≠ fine, RPC sigue funcionando pero el catalog row más apropiado es obligation.forgive.'
   ))
on conflict (action_key) do update set
  display_name = excluded.display_name,
  domain = excluded.domain,
  default_requires_decision = excluded.default_requires_decision,
  policy_key = excluded.policy_key,
  execution_rpc = excluded.execution_rpc,
  push_supported = excluded.push_supported,
  dangerous = excluded.dangerous,
  metadata = excluded.metadata,
  updated_at = now();
