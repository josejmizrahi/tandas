-- §9. Money 2.0
create or replace function public.record_expense(
  p_group_id            uuid,
  p_resource_id         uuid,
  p_amount              numeric,
  p_unit                text,
  p_paid_by_membership_id uuid,
  p_description         text default null,
  p_split_mode          text default 'even',
  p_split_breakdown     jsonb default null,
  p_in_kind             boolean default false,
  p_client_id           text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx_id uuid;
  v_resource_group uuid;
  v_n int;
  v_per numeric;
  v_member jsonb;
begin
  perform public.assert_permission(p_group_id, 'expense.record');
  if p_resource_id is not null then
    select group_id into v_resource_group from public.group_resources where id = p_resource_id;
    if v_resource_group is distinct from p_group_id then
      raise exception 'resource % not in group %', p_resource_id, p_group_id;
    end if;
  end if;
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  if p_client_id is not null then
    select id into v_tx_id from public.group_resource_transactions
     where group_id = p_group_id and client_id = p_client_id;
    if v_tx_id is not null then return v_tx_id; end if;
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, paid_by_membership_id,
    amount, unit, source_resource_id, source_entity_kind,
    split_breakdown, split_mode, in_kind, description, client_id, recorded_by
  ) values (
    p_group_id, p_resource_id, 'expense', p_paid_by_membership_id,
    p_amount, p_unit, p_resource_id, 'manual',
    p_split_breakdown, p_split_mode, p_in_kind, p_description, p_client_id, auth.uid()
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
            source_transaction_id, source_resource_id,
            obligation_kind, amount_original, amount_outstanding, unit, description
          ) values (
            p_group_id, (v_member->>'membership_id')::uuid, p_paid_by_membership_id, 'member',
            v_tx_id, p_resource_id,
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
            source_transaction_id, source_resource_id,
            obligation_kind, amount_original, amount_outstanding, unit, description
          ) values (
            p_group_id, (v_member->>'membership_id')::uuid, p_paid_by_membership_id, 'member',
            v_tx_id, p_resource_id,
            'expense_share',
            (v_member->>'amount')::numeric,
            (v_member->>'amount')::numeric,
            p_unit, p_description
          );
        end if;
      end loop;
    end if;
  end if;

  perform public.record_system_event(
    p_group_id, 'money.expense_recorded', 'transaction', v_tx_id, p_description,
    jsonb_build_object('amount', p_amount, 'unit', p_unit)
  );
  return v_tx_id;
end;
$$;

create or replace function public.record_contribution(
  p_group_id        uuid,
  p_resource_id     uuid default null,
  p_amount          numeric default null,
  p_unit            text default 'MXN',
  p_from_membership_id uuid default null,
  p_description     text default null,
  p_in_kind         boolean default false,
  p_client_id       text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_tx uuid;
begin
  perform public.assert_permission(p_group_id, 'contribution.record');
  if p_amount is null or p_amount <= 0 then raise exception 'amount required'; end if;
  if p_client_id is not null then
    select id into v_tx from public.group_resource_transactions
     where group_id = p_group_id and client_id = p_client_id;
    if v_tx is not null then return v_tx; end if;
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, from_membership_id,
    amount, unit, source_resource_id, source_entity_kind,
    in_kind, description, client_id, recorded_by
  ) values (
    p_group_id, p_resource_id, 'contribution', p_from_membership_id,
    p_amount, p_unit, p_resource_id, 'contribution',
    p_in_kind, p_description, p_client_id, auth.uid()
  ) returning id into v_tx;

  perform public.record_system_event(
    p_group_id, 'money.contribution_recorded', 'transaction', v_tx, p_description,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'in_kind', p_in_kind)
  );
  return v_tx;
end;
$$;

create or replace function public.record_non_monetary_contribution(
  p_group_id         uuid,
  p_membership_id    uuid,
  p_contribution_type text,
  p_title            text,
  p_description      text default null,
  p_source_resource_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'contribution.record');
  insert into public.group_contributions (
    group_id, membership_id, contribution_type, title, description, source_resource_id, status
  ) values (
    p_group_id, p_membership_id, p_contribution_type, p_title, p_description, p_source_resource_id, 'claimed'
  ) returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'contribution.recorded', 'contribution', v_id, p_title,
    jsonb_build_object('type', p_contribution_type)
  );
  return v_id;
end;
$$;

create or replace function public.verify_contribution(
  p_contribution_id uuid,
  p_outcome         text,
  p_note            text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_c public.group_contributions%rowtype;
begin
  if p_outcome not in ('verified','rejected') then raise exception 'invalid outcome'; end if;
  select * into v_c from public.group_contributions where id = p_contribution_id for update;
  if v_c.id is null then raise exception 'contribution not found'; end if;
  perform public.assert_permission(v_c.group_id, 'records.read');

  update public.group_contributions
     set status = p_outcome, verified_by = auth.uid(),
         metadata = metadata || jsonb_build_object('verifier_note', p_note)
   where id = p_contribution_id;

  if p_outcome = 'verified' then
    insert into public.group_reputation_events (
      group_id, subject_membership_id, actor_membership_id,
      reputation_type, reason, evidence_entity_kind, evidence_entity_id
    ) values (
      v_c.group_id, v_c.membership_id,
      (select id from public.group_memberships where group_id = v_c.group_id and user_id = auth.uid()),
      'contribution_recognized', p_note, 'contribution', p_contribution_id
    );
  end if;

  perform public.record_system_event(
    v_c.group_id, 'contribution.' || p_outcome, 'contribution', p_contribution_id, p_note, '{}'::jsonb
  );
end;
$$;

create or replace function public.record_settlement(
  p_group_id            uuid,
  p_paid_by_membership_id uuid,
  p_paid_to_membership_id uuid,
  p_paid_to_kind        text,
  p_amount              numeric,
  p_unit                text,
  p_notes               text default null,
  p_client_id           text default null
)
returns table (settlement_id uuid, transaction_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement uuid;
  v_tx_id      uuid;
  v_remaining  numeric := p_amount;
  v_close      numeric;
  v_o          public.group_obligations%rowtype;
  v_actor_m    uuid;
begin
  perform public.assert_permission(p_group_id, 'settlement.record');
  if p_paid_to_kind not in ('member','pool','vendor','group') then raise exception 'invalid paid_to_kind'; end if;
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  if p_client_id is not null then
    select id into v_settlement from public.group_settlements
     where group_id = p_group_id and client_id = p_client_id;
    if v_settlement is not null then
      select ledger_entry_id into v_tx_id from public.group_settlements where id = v_settlement;
      return query select v_settlement, v_tx_id;
      return;
    end if;
  end if;

  insert into public.group_settlements (
    group_id, paid_by_membership_id, paid_to_membership_id, paid_to_kind,
    amount, unit, status, client_id, notes, recorded_by, confirmed_at
  ) values (
    p_group_id, p_paid_by_membership_id, p_paid_to_membership_id, p_paid_to_kind,
    p_amount, p_unit, 'confirmed', p_client_id, p_notes, auth.uid(), now()
  ) returning id into v_settlement;

  v_actor_m := (select id from public.group_memberships where group_id = p_group_id and user_id = auth.uid());

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

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type,
    from_membership_id, to_membership_id, paid_by_membership_id,
    amount, unit, source_entity_kind, source_entity_id,
    description, recorded_by
  )
  select p_group_id,
         (select coalesce(min(o.source_resource_id), null)
            from public.group_settlement_obligations so
            join public.group_obligations o on o.id = so.obligation_id
            where so.settlement_id = v_settlement),
         'settlement_payment',
         p_paid_by_membership_id,
         case when p_paid_to_kind = 'member' then p_paid_to_membership_id else null end,
         p_paid_by_membership_id,
         p_amount, p_unit, 'settlement', v_settlement,
         p_notes, auth.uid()
  returning id into v_tx_id;

  update public.group_settlements
     set ledger_entry_id = v_tx_id,
         metadata = case when v_remaining > 0
                         then metadata || jsonb_build_object('unallocated', v_remaining)
                         else metadata end
   where id = v_settlement;

  perform public.record_system_event(
    p_group_id, 'money.settlement_recorded', 'settlement', v_settlement, p_notes,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'unallocated', v_remaining)
  );

  return query select v_settlement, v_tx_id;
end;
$$;

create or replace function public.record_pool_charge(
  p_group_id            uuid,
  p_target_membership_id uuid,
  p_amount              numeric,
  p_unit                text,
  p_charge_kind         text,
  p_reason              text default null,
  p_client_id           text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'pool_charge.record');
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_charge_kind not in ('quota','buy_in','fee') then raise exception 'invalid charge_kind'; end if;

  insert into public.group_obligations (
    group_id, owed_by_membership_id, owed_to_kind,
    obligation_kind, amount_original, amount_outstanding, unit,
    description, metadata
  ) values (
    p_group_id, p_target_membership_id, 'pool',
    'pool_charge', p_amount, p_amount, p_unit,
    p_reason, jsonb_build_object('charge_kind', p_charge_kind, 'client_id', p_client_id)
  ) returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'money.pool_charge_created', 'obligation', v_id, p_reason,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'kind', p_charge_kind, 'target', p_target_membership_id)
  );
  return v_id;
end;
$$;

create or replace function public.record_payout(
  p_group_id          uuid,
  p_to_membership_id  uuid,
  p_amount            numeric,
  p_unit              text,
  p_source_resource_id uuid default null,
  p_reason            text default null,
  p_client_id         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_tx uuid;
begin
  perform public.assert_permission(p_group_id, 'payout.record');
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, to_membership_id,
    amount, unit, source_resource_id, description, client_id, recorded_by
  ) values (
    p_group_id, p_source_resource_id, 'payout', p_to_membership_id,
    p_amount, p_unit, p_source_resource_id, p_reason, p_client_id, auth.uid()
  ) returning id into v_tx;

  perform public.record_system_event(
    p_group_id, 'money.payout_recorded', 'transaction', v_tx, p_reason,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'to', p_to_membership_id)
  );
  return v_tx;
end;
$$;

create or replace function public.reverse_transaction(
  p_transaction_id uuid,
  p_reason         text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_tx public.group_resource_transactions%rowtype; v_new uuid;
begin
  select * into v_tx from public.group_resource_transactions where id = p_transaction_id;
  if v_tx.id is null then raise exception 'transaction not found'; end if;
  if v_tx.recorded_by <> auth.uid() and not public.has_group_permission(v_tx.group_id, 'records.read') then
    raise exception 'caller cannot reverse this transaction';
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type,
    from_membership_id, to_membership_id, paid_by_membership_id,
    amount, unit, source_entity_kind, source_entity_id,
    reversed_entry_id, description, recorded_by
  ) values (
    v_tx.group_id, v_tx.resource_id, 'reversal',
    v_tx.to_membership_id, v_tx.from_membership_id, v_tx.paid_by_membership_id,
    v_tx.amount, v_tx.unit, 'manual', null,
    p_transaction_id, p_reason, auth.uid()
  ) returning id into v_new;

  perform public.record_system_event(
    v_tx.group_id, 'money.transaction_reversed', 'transaction', p_transaction_id, p_reason,
    jsonb_build_object('reversal_id', v_new)
  );
  return v_new;
end;
$$;

create or replace function public.record_asset_valuation(
  p_resource_id uuid,
  p_value       numeric,
  p_unit        text,
  p_basis       text default 'member_estimate'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid; v_id uuid;
begin
  select group_id into v_group from public.group_resources where id = p_resource_id;
  if v_group is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  insert into public.group_resource_asset_valuations (resource_id, value, unit, basis, recorded_by)
  values (p_resource_id, p_value, p_unit, p_basis, auth.uid())
  returning id into v_id;

  update public.group_resource_assets
     set current_value = p_value, current_value_unit = p_unit
   where resource_id = p_resource_id;

  perform public.record_system_event(
    v_group, 'asset.valuation_recorded', 'resource', p_resource_id, p_basis,
    jsonb_build_object('value', p_value, 'unit', p_unit)
  );
  return v_id;
end;
$$;

-- §10. Sanctions
create or replace function public.issue_sanction(
  p_group_id             uuid,
  p_target_membership_id uuid,
  p_sanction_kind        text,
  p_reason               text,
  p_amount               numeric default null,
  p_unit                 text default null,
  p_ends_at              timestamptz default null,
  p_rule_version_id      uuid default null,
  p_source_event_id      uuid default null,
  p_client_id            text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_obligation uuid; v_actor uuid;
begin
  perform public.assert_permission(p_group_id, 'sanctions.create');
  if p_client_id is not null then
    select id into v_id from public.group_sanctions
     where group_id = p_group_id and client_id = p_client_id;
    if v_id is not null then return v_id; end if;
  end if;

  v_actor := (select id from public.group_memberships where group_id = p_group_id and user_id = auth.uid());

  insert into public.group_sanctions (
    group_id, target_membership_id, issued_by_membership_id, rule_version_id,
    source_event_id, sanction_kind, status, amount, unit, reason, ends_at, client_id
  ) values (
    p_group_id, p_target_membership_id, v_actor, p_rule_version_id,
    p_source_event_id, p_sanction_kind, 'active', p_amount, p_unit, p_reason, p_ends_at, p_client_id
  ) returning id into v_id;

  if p_sanction_kind = 'monetary' then
    if p_amount is null or p_amount <= 0 or p_unit is null then
      raise exception 'monetary sanction requires positive amount + unit';
    end if;
    insert into public.group_obligations (
      group_id, owed_by_membership_id, owed_to_kind,
      obligation_kind, amount_original, amount_outstanding, unit, description, metadata
    ) values (
      p_group_id, p_target_membership_id, 'pool',
      'fine', p_amount, p_amount, p_unit, p_reason,
      jsonb_build_object('sanction_id', v_id)
    ) returning id into v_obligation;
    update public.group_sanctions set obligation_id = v_obligation where id = v_id;
  elsif p_sanction_kind = 'suspension' then
    perform public.set_membership_state(p_target_membership_id, 'suspended', p_reason, p_ends_at);
  end if;

  insert into public.group_reputation_events (
    group_id, subject_membership_id, actor_membership_id,
    reputation_type, reason, evidence_entity_kind, evidence_entity_id
  ) values (
    p_group_id, p_target_membership_id, v_actor,
    case when p_rule_version_id is not null then 'rule_violation' else 'commitment_broken' end,
    p_reason, 'sanction', v_id
  );

  perform public.record_system_event(
    p_group_id, 'sanction.issued', 'sanction', v_id, p_reason,
    jsonb_build_object('kind', p_sanction_kind, 'target', p_target_membership_id)
  );
  return v_id;
end;
$$;

create or replace function public.update_sanction_status(
  p_sanction_id uuid,
  p_new_status  text,
  p_reason      text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_s public.group_sanctions%rowtype;
begin
  select * into v_s from public.group_sanctions where id = p_sanction_id for update;
  if v_s.id is null then raise exception 'sanction not found'; end if;
  if p_new_status not in ('reversed','completed','cancelled') then raise exception 'invalid status'; end if;
  perform public.assert_permission(v_s.group_id, 'sanctions.update');

  update public.group_sanctions
     set status = p_new_status, resolved_at = now(),
         metadata = metadata || jsonb_build_object('resolution_reason', p_reason)
   where id = p_sanction_id;

  if p_new_status = 'reversed' and v_s.obligation_id is not null then
    update public.group_obligations
       set status = 'voided', amount_outstanding = 0,
           metadata = metadata || jsonb_build_object('voided_reason', 'sanction_reversed')
     where id = v_s.obligation_id;
  end if;

  perform public.record_system_event(
    v_s.group_id, 'sanction.' || p_new_status, 'sanction', p_sanction_id, p_reason, '{}'::jsonb
  );
end;
$$;
