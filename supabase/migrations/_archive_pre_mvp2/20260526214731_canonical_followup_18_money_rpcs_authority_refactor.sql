-- P1+P2+P7: Refactor de las 5 money RPCs para usar _resolve_authority_path.
-- - mandate_id explícito gana siempre el path
-- - self_party bypassea permission check
-- - direct_permission para record_expense exige expense.record_for_others (P7)

create or replace function public.record_expense(
  p_group_id              uuid,
  p_resource_id           uuid,
  p_amount                numeric,
  p_unit                  text,
  p_paid_by_membership_id uuid,
  p_description           text default null,
  p_split_mode            text default 'even',
  p_split_breakdown       jsonb default null,
  p_in_kind               boolean default false,
  p_mandate_id            uuid default null,
  p_client_id             text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx_id           uuid;
  v_resource_group  uuid;
  v_actor_m         uuid;
  v_authority_path  text;
  v_event_uuid      uuid;
  v_n               int;
  v_per             numeric;
  v_member          jsonb;
  v_sum             numeric;
begin
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_resource_id is not null then
    select gr.group_id into v_resource_group from public.group_resources gr where gr.id = p_resource_id;
    if v_resource_group is distinct from p_group_id then
      raise exception 'resource % not in group %', p_resource_id, p_group_id;
    end if;
  end if;

  if p_client_id is not null then
    select grt.id into v_tx_id from public.group_resource_transactions grt
     where grt.group_id = p_group_id and grt.client_id = p_client_id;
    if v_tx_id is not null then return v_tx_id; end if;
  end if;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = p_group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_actor_m is null then
    raise exception 'caller is not an active member of group %', p_group_id;
  end if;

  v_authority_path := public._resolve_authority_path(
    p_group_id         => p_group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => (p_paid_by_membership_id = v_actor_m),
    p_mandate_id       => p_mandate_id,
    p_permission       => 'expense.record_for_others',
    p_mandate_scope    => 'spend',
    p_amount           => p_amount,
    p_unit             => p_unit,
    p_resource_id      => p_resource_id
  );

  if not p_in_kind and p_split_mode = 'custom' and p_split_breakdown is not null then
    select coalesce(sum((m->>'amount')::numeric), 0) into v_sum
      from jsonb_array_elements(p_split_breakdown) m;
    if abs(v_sum - p_amount) > 0.0001 then
      raise exception 'custom split sum % does not match amount %', v_sum, p_amount;
    end if;
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, paid_by_membership_id,
    amount, unit, source_resource_id, source_entity_kind,
    split_breakdown, split_mode, in_kind, description,
    mandate_id, client_id, recorded_by
  ) values (
    p_group_id, p_resource_id, 'expense', p_paid_by_membership_id,
    p_amount, p_unit, p_resource_id, 'manual',
    p_split_breakdown, p_split_mode, p_in_kind, p_description,
    p_mandate_id, p_client_id, auth.uid()
  ) returning id into v_tx_id;

  if not p_in_kind and p_split_mode is not null and p_split_mode <> 'none' then
    if p_split_mode = 'even' and p_split_breakdown is not null then
      v_n := jsonb_array_length(p_split_breakdown);
      v_per := round(p_amount / nullif(v_n, 0), 4);
      for v_member in select * from jsonb_array_elements(p_split_breakdown)
      loop
        if (v_member->>'membership_id')::uuid <> p_paid_by_membership_id then
          insert into public.group_obligations (
            group_id, owed_by_membership_id, owed_to_membership_id, owed_to_kind,
            source_transaction_id, source_resource_id, source_mandate_id,
            obligation_kind, amount_original, amount_outstanding, unit, description
          ) values (
            p_group_id, (v_member->>'membership_id')::uuid, p_paid_by_membership_id, 'member',
            v_tx_id, p_resource_id, p_mandate_id,
            'expense_share', v_per, v_per, p_unit, p_description
          );
        end if;
      end loop;
    elsif p_split_mode = 'custom' and p_split_breakdown is not null then
      for v_member in select * from jsonb_array_elements(p_split_breakdown)
      loop
        if (v_member->>'membership_id')::uuid <> p_paid_by_membership_id then
          insert into public.group_obligations (
            group_id, owed_by_membership_id, owed_to_membership_id, owed_to_kind,
            source_transaction_id, source_resource_id, source_mandate_id,
            obligation_kind, amount_original, amount_outstanding, unit, description
          ) values (
            p_group_id, (v_member->>'membership_id')::uuid, p_paid_by_membership_id, 'member',
            v_tx_id, p_resource_id, p_mandate_id,
            'expense_share',
            (v_member->>'amount')::numeric,
            (v_member->>'amount')::numeric,
            p_unit, p_description
          );
        end if;
      end loop;
    end if;
  end if;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'money.expense_recorded', 'transaction', v_tx_id, p_description,
    jsonb_build_object(
      'amount', p_amount,
      'unit', p_unit,
      'authority_path', v_authority_path,
      'mandate_id', p_mandate_id,
      'paid_by_membership_id', p_paid_by_membership_id,
      'split_mode', p_split_mode
    )
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  return v_tx_id;
end;
$$;

create or replace function public.record_contribution(
  p_group_id           uuid,
  p_resource_id        uuid default null,
  p_amount             numeric default null,
  p_unit               text default 'MXN',
  p_from_membership_id uuid default null,
  p_description        text default null,
  p_in_kind            boolean default false,
  p_mandate_id         uuid default null,
  p_client_id          text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx_id          uuid;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'amount required'; end if;

  if p_client_id is not null then
    select grt.id into v_tx_id from public.group_resource_transactions grt
     where grt.group_id = p_group_id and grt.client_id = p_client_id;
    if v_tx_id is not null then return v_tx_id; end if;
  end if;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = p_group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_actor_m is null then
    raise exception 'caller is not an active member of group %', p_group_id;
  end if;

  v_authority_path := public._resolve_authority_path(
    p_group_id         => p_group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => (p_from_membership_id is null or p_from_membership_id = v_actor_m),
    p_mandate_id       => p_mandate_id,
    p_permission       => 'contribution.record',
    p_mandate_scope    => 'contribute',
    p_amount           => p_amount,
    p_unit             => p_unit,
    p_resource_id      => p_resource_id
  );

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, from_membership_id,
    amount, unit, source_resource_id, source_entity_kind,
    in_kind, description, mandate_id, client_id, recorded_by
  ) values (
    p_group_id, p_resource_id, 'contribution', p_from_membership_id,
    p_amount, p_unit, p_resource_id, 'contribution',
    p_in_kind, p_description, p_mandate_id, p_client_id, auth.uid()
  ) returning id into v_tx_id;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'money.contribution_recorded', 'transaction', v_tx_id, p_description,
    jsonb_build_object(
      'amount', p_amount,
      'unit', p_unit,
      'in_kind', p_in_kind,
      'authority_path', v_authority_path,
      'mandate_id', p_mandate_id,
      'from_membership_id', p_from_membership_id
    )
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  return v_tx_id;
end;
$$;

create or replace function public.record_settlement(
  p_group_id              uuid,
  p_paid_by_membership_id uuid,
  p_paid_to_membership_id uuid,
  p_paid_to_kind          text,
  p_amount                numeric,
  p_unit                  text,
  p_notes                 text default null,
  p_mandate_id            uuid default null,
  p_client_id             text default null
)
returns table (settlement_id uuid, transaction_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement     uuid;
  v_tx_id          uuid;
  v_remaining      numeric;
  v_close          numeric;
  v_o              public.group_obligations%rowtype;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
  v_existing_tx    uuid;
  v_source_resource uuid;
begin
  if p_paid_to_kind not in ('member','pool','vendor','group') then
    raise exception 'invalid paid_to_kind';
  end if;
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  v_remaining := p_amount;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = p_group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_actor_m is null then
    raise exception 'caller is not an active member of group %', p_group_id;
  end if;

  if p_client_id is not null then
    select gs.id, gs.ledger_entry_id into v_settlement, v_existing_tx
      from public.group_settlements gs
     where gs.group_id = p_group_id and gs.client_id = p_client_id;
    if v_settlement is not null then
      settlement_id := v_settlement;
      transaction_id := v_existing_tx;
      return next;
      return;
    end if;
  end if;

  v_authority_path := public._resolve_authority_path(
    p_group_id         => p_group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => (p_paid_by_membership_id = v_actor_m),
    p_mandate_id       => p_mandate_id,
    p_permission       => 'settlement.record',
    p_mandate_scope    => 'settle',
    p_amount           => p_amount,
    p_unit             => p_unit,
    p_resource_id      => null
  );

  insert into public.group_settlements (
    group_id, paid_by_membership_id, paid_to_membership_id, paid_to_kind,
    amount, unit, status, mandate_id, client_id, notes, recorded_by, confirmed_at
  ) values (
    p_group_id, p_paid_by_membership_id, p_paid_to_membership_id, p_paid_to_kind,
    p_amount, p_unit, 'confirmed', p_mandate_id, p_client_id, p_notes, auth.uid(), now()
  ) returning id into v_settlement;

  for v_o in
    select * from public.group_obligations
     where group_id = p_group_id
       and owed_by_membership_id = p_paid_by_membership_id
       and ((p_paid_to_kind = 'member' and owed_to_membership_id = p_paid_to_membership_id)
            or (p_paid_to_kind <> 'member' and owed_to_kind = p_paid_to_kind))
       and unit = p_unit
       and status in ('open','partially_settled')
     order by created_at asc
     for update
  loop
    exit when v_remaining <= 0;
    v_close := least(v_remaining, v_o.amount_outstanding);

    insert into public.group_settlement_obligations (settlement_id, obligation_id, amount_closed)
    values (v_settlement, v_o.id, v_close);

    update public.group_obligations
       set amount_outstanding = amount_outstanding - v_close,
           status = case
             when (amount_outstanding - v_close) <= 0 then 'settled'
             else 'partially_settled'
           end
     where id = v_o.id;

    if v_close = v_o.amount_outstanding then
      insert into public.group_reputation_events (
        group_id, subject_membership_id, actor_membership_id,
        reputation_type, reason, evidence_entity_kind, evidence_entity_id
      ) values (
        p_group_id, p_paid_by_membership_id, v_actor_m,
        'commitment_kept', 'Obligación cerrada', 'obligation', v_o.id
      );
    end if;

    v_remaining := v_remaining - v_close;
  end loop;

  select o.source_resource_id into v_source_resource
    from public.group_settlement_obligations so
    join public.group_obligations o on o.id = so.obligation_id
    where so.settlement_id = v_settlement
      and o.source_resource_id is not null
    limit 1;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type,
    from_membership_id, to_membership_id, paid_by_membership_id,
    amount, unit, source_entity_kind, source_entity_id,
    mandate_id, description, recorded_by
  ) values (
    p_group_id, v_source_resource, 'settlement_payment',
    p_paid_by_membership_id,
    case when p_paid_to_kind = 'member' then p_paid_to_membership_id else null end,
    p_paid_by_membership_id,
    p_amount, p_unit, 'settlement', v_settlement,
    p_mandate_id, p_notes, auth.uid()
  ) returning id into v_tx_id;

  update public.group_settlements
     set ledger_entry_id = v_tx_id,
         metadata = case when v_remaining > 0
                         then metadata || jsonb_build_object('unallocated', v_remaining)
                         else metadata end
   where id = v_settlement;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'money.settlement_recorded', 'settlement', v_settlement, p_notes,
    jsonb_build_object(
      'amount', p_amount,
      'unit', p_unit,
      'authority_path', v_authority_path,
      'mandate_id', p_mandate_id,
      'paid_by_membership_id', p_paid_by_membership_id,
      'paid_to_kind', p_paid_to_kind,
      'unallocated', v_remaining
    )
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  settlement_id := v_settlement;
  transaction_id := v_tx_id;
  return next;
  return;
end;
$$;

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
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_charge_kind not in ('quota','buy_in','fee') then raise exception 'invalid charge_kind'; end if;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = p_group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_actor_m is null then
    raise exception 'caller is not an active member of group %', p_group_id;
  end if;

  v_authority_path := public._resolve_authority_path(
    p_group_id         => p_group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => false,
    p_mandate_id       => p_mandate_id,
    p_permission       => 'pool_charge.record',
    p_mandate_scope    => 'charge',
    p_amount           => p_amount,
    p_unit             => p_unit,
    p_resource_id      => null
  );

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
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = p_group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_actor_m is null then
    raise exception 'caller is not an active member of group %', p_group_id;
  end if;

  v_authority_path := public._resolve_authority_path(
    p_group_id         => p_group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => false,
    p_mandate_id       => p_mandate_id,
    p_permission       => 'payout.record',
    p_mandate_scope    => 'payout',
    p_amount           => p_amount,
    p_unit             => p_unit,
    p_resource_id      => p_source_resource_id
  );

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
