drop function if exists public.record_pool_charge(uuid, uuid, numeric, text, text, text, text);

create or replace function public.record_pool_charge(
  p_group_id             uuid,
  p_target_membership_id uuid,
  p_amount               numeric,
  p_unit                 text,
  p_charge_kind          text,
  p_reason               text default null,
  p_mandate_id           uuid default null,
  p_client_id            text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id             uuid;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
begin
  perform public.assert_permission(p_group_id, 'pool_charge.record');
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_charge_kind not in ('quota','buy_in','fee') then raise exception 'invalid charge_kind'; end if;

  v_actor_m := (select id from public.group_memberships
                where group_id = p_group_id and user_id = auth.uid() and status = 'active');

  if p_mandate_id is not null then
    perform public._assert_mandate_authorizes(
      p_mandate_id, p_group_id, v_actor_m, 'charge',
      p_amount, p_unit, null
    );
    v_authority_path := 'mandate';
  else
    v_authority_path := 'direct_permission';
  end if;

  insert into public.group_obligations (
    group_id, owed_by_membership_id, owed_to_kind,
    obligation_kind, amount_original, amount_outstanding, unit,
    description, source_mandate_id, metadata
  ) values (
    p_group_id, p_target_membership_id, 'pool',
    'pool_charge', p_amount, p_amount, p_unit,
    p_reason, p_mandate_id,
    jsonb_build_object('charge_kind', p_charge_kind, 'client_id', p_client_id)
  ) returning id into v_id;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'money.pool_charge_created', 'obligation', v_id, p_reason,
    jsonb_build_object(
      'amount', p_amount,
      'unit', p_unit,
      'kind', p_charge_kind,
      'target', p_target_membership_id,
      'authority_path', v_authority_path,
      'mandate_id', p_mandate_id
    )
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  return v_id;
end;
$$;

drop function if exists public.record_payout(uuid, uuid, numeric, text, uuid, text, text);

create or replace function public.record_payout(
  p_group_id           uuid,
  p_to_membership_id   uuid,
  p_amount             numeric,
  p_unit               text,
  p_source_resource_id uuid default null,
  p_reason             text default null,
  p_mandate_id         uuid default null,
  p_client_id          text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx             uuid;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
begin
  perform public.assert_permission(p_group_id, 'payout.record');
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  v_actor_m := (select id from public.group_memberships
                where group_id = p_group_id and user_id = auth.uid() and status = 'active');

  if p_mandate_id is not null then
    perform public._assert_mandate_authorizes(
      p_mandate_id, p_group_id, v_actor_m, 'payout',
      p_amount, p_unit, p_source_resource_id
    );
    v_authority_path := 'mandate';
  else
    v_authority_path := 'direct_permission';
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, to_membership_id,
    amount, unit, source_resource_id, description, mandate_id, client_id, recorded_by
  ) values (
    p_group_id, p_source_resource_id, 'payout', p_to_membership_id,
    p_amount, p_unit, p_source_resource_id, p_reason, p_mandate_id, p_client_id, auth.uid()
  ) returning id into v_tx;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'money.payout_recorded', 'transaction', v_tx, p_reason,
    jsonb_build_object(
      'amount', p_amount,
      'unit', p_unit,
      'to', p_to_membership_id,
      'authority_path', v_authority_path,
      'mandate_id', p_mandate_id,
      'source_resource_id', p_source_resource_id
    )
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  return v_tx;
end;
$$;
