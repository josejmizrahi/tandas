-- R.7.x.2 — transfer_resource_ownership governance-aware + catalog wire + recipient validation
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md (R.7.x #2/4)
-- transfer_resource_ownership existing (F.1A polish) extended:
--   1. PULL gate doctrine R.7: policy=true OR (null+catalog default) → governance required
--   2. Governance-driven path: _governance_action_approved → bypass caller-must-own, v_from=canonical_owner
--   3. Recipient validation: si canonical_owner es context actor (collective/legal_entity), recipient debe ser active member
--   4. Dispatch wire + catalog flip resource.transfer push_supported=true

-- §1 transfer_resource_ownership
create or replace function public.transfer_resource_ownership(
  p_resource_id uuid,
  p_to_actor_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
  v_recipient public.actors%rowtype;
  v_owner_actor public.actors%rowtype;
  v_ga uuid;
  v_via_governance boolean;
  v_from uuid;
  v_total_percent numeric;
  v_all_null boolean;
  v_revoked_count int;
  v_new_right_id uuid;
  v_was_canonical boolean;
  v_pol jsonb;
  v_catalog_default boolean;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if v_resource.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;

  select * into v_recipient from public.actors where id = p_to_actor_id;
  if v_recipient.id is null then raise exception 'recipient actor not found' using errcode = 'P0002'; end if;

  if not public.actor_can(p_to_actor_id, 'can_own_resources') then
    raise exception 'recipient cannot own resources (missing can_own_resources capability)' using errcode = '42501';
  end if;

  -- Defensive validation: si canonical_owner es context actor (collective/legal_entity),
  -- recipient debe ser miembro activo (evita ownership leak a outsiders).
  select * into v_owner_actor from public.actors where id = v_resource.canonical_owner_actor_id;
  if v_owner_actor.actor_kind in ('collective', 'legal_entity')
     and p_to_actor_id <> v_resource.canonical_owner_actor_id
     and not exists (
       select 1 from public.actor_memberships
       where context_actor_id = v_resource.canonical_owner_actor_id
         and member_actor_id = p_to_actor_id
         and membership_status = 'active'
     ) then
    raise exception 'recipient % is not an active member of context %', p_to_actor_id, v_resource.canonical_owner_actor_id
      using errcode = '42501';
  end if;

  -- Check governance approval first (auto-detect path)
  v_ga := public._governance_action_approved(
    v_resource.canonical_owner_actor_id, 'resource.transfer', p_resource_id);
  v_via_governance := (v_ga is not null);

  if v_via_governance then
    v_from := v_resource.canonical_owner_actor_id;
  else
    -- Direct path: PULL gate doctrine R.7
    v_pol := public.governance_policy(v_resource.canonical_owner_actor_id, 'resource_transfer_requires_vote');
    select default_requires_decision into v_catalog_default
      from public.governance_action_catalog where action_key = 'resource.transfer';
    if v_pol = 'true'::jsonb or (v_pol is null and coalesce(v_catalog_default, false)) then
      raise exception 'governance_required: resource.transfer requires an approved decision in this context'
        using errcode = '42501',
        hint = 'call request_governance_action(canonical_owner, ''resource.transfer'', ''resource'', resource_id, jsonb_build_object(''to_actor_id'', recipient)) and get it approved first';
    end if;
    v_from := v_caller;
  end if;

  if v_from = p_to_actor_id then
    raise exception 'cannot transfer ownership to current owner' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.resource_rights
    where resource_id = p_resource_id and holder_actor_id = v_from
      and right_kind = 'OWN' and revoked_at is null and expired_at is null
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at > now())
  ) then
    raise exception 'no active OWN right found for actor %', v_from using errcode = '42501';
  end if;

  select bool_and(percent is null), coalesce(sum(percent), 0)
    into v_all_null, v_total_percent
    from public.resource_rights
   where resource_id = p_resource_id and holder_actor_id = v_from
     and right_kind = 'OWN' and revoked_at is null and expired_at is null
     and (starts_at is null or starts_at <= now())
     and (ends_at is null or ends_at > now());

  with revoked as (
    update public.resource_rights
       set revoked_at = now(),
           updated_at = now(),
           metadata = coalesce(metadata, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
             'transferred_to', p_to_actor_id,
             'transfer_reason', p_reason,
             'via_governance', v_via_governance,
             'governance_action_id', v_ga
           ))
     where resource_id = p_resource_id and holder_actor_id = v_from
       and right_kind = 'OWN' and revoked_at is null
     returning 1
  )
  select count(*) into v_revoked_count from revoked;

  v_new_right_id := (public.grant_right(
    p_resource_id := p_resource_id,
    p_holder_actor_id := p_to_actor_id,
    p_right_kind := 'OWN',
    p_percent := case when v_all_null then null else v_total_percent end,
    p_metadata := jsonb_strip_nulls(jsonb_build_object(
      'transferred_from', v_from,
      'transfer_reason', p_reason,
      'via_governance', v_via_governance,
      'governance_action_id', v_ga
    ))
  ) ->> 'right_id')::uuid;

  v_was_canonical := (v_resource.canonical_owner_actor_id = v_from);
  if v_was_canonical then
    update public.resources
       set canonical_owner_actor_id = p_to_actor_id,
           updated_at = now()
     where id = p_resource_id;
  end if;

  if v_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_ga;
  end if;

  perform public._emit_activity(
    coalesce(v_resource.canonical_owner_actor_id, p_to_actor_id),
    v_caller, 'right.transferred', 'resource', p_resource_id,
    jsonb_strip_nulls(jsonb_build_object(
      'from', v_from,
      'to', p_to_actor_id,
      'right_kind', 'OWN',
      'percent_total', case when v_all_null then null else v_total_percent end,
      'rights_revoked', v_revoked_count,
      'canonical_owner_changed', v_was_canonical,
      'reason', p_reason,
      'via_governance', v_via_governance,
      'governance_action_id', v_ga
    )),
    p_resource_id := p_resource_id
  );

  return jsonb_build_object(
    'resource_id', p_resource_id,
    'from_actor_id', v_from,
    'to_actor_id', p_to_actor_id,
    'new_right_id', v_new_right_id,
    'rights_revoked', v_revoked_count,
    'percent_total', case when v_all_null then null else v_total_percent end,
    'canonical_owner_changed', v_was_canonical,
    'via_governance', v_via_governance
  );
end;
$$;

comment on function public.transfer_resource_ownership(uuid, uuid, text) is
  'R.7.x.2 — Atomic resource ownership transfer with governance-aware PULL gate.
Auto-detects governance approval via _governance_action_approved → if found, bypasses
caller-must-own check and uses canonical_owner as v_from. If not, requires PULL gate:
policy=true OR (null+catalog default_requires_decision=true). Defensive: recipient
must be active member if canonical_owner is collective/legal_entity actor.';

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

    else
      raise exception 'execute_governance_action: execution_rpc % not supported in R.7 dispatch',
        p_catalog.execution_rpc using errcode = 'P0001';
  end case;

  return v_result;
end;
$$;

-- §3 catalog flip resource.transfer
update public.governance_action_catalog
   set execution_rpc = 'transfer_resource_ownership',
       push_supported = true,
       updated_at = now()
 where action_key = 'resource.transfer';
