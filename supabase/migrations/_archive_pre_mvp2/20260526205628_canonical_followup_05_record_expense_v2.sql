-- record_expense v2 con mandate + authority_path + split validation + sync rule eval.
-- Drop the old signature (new has different param list).

drop function if exists public.record_expense(uuid, uuid, numeric, text, uuid, text, text, jsonb, boolean, text);

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
  perform public.assert_permission(p_group_id, 'expense.record');
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  if p_resource_id is not null then
    select group_id into v_resource_group from public.group_resources where id = p_resource_id;
    if v_resource_group is distinct from p_group_id then
      raise exception 'resource % not in group %', p_resource_id, p_group_id;
    end if;
  end if;

  if p_client_id is not null then
    select id into v_tx_id from public.group_resource_transactions
     where group_id = p_group_id and client_id = p_client_id;
    if v_tx_id is not null then return v_tx_id; end if;
  end if;

  v_actor_m := (select id from public.group_memberships
                where group_id = p_group_id and user_id = auth.uid() and status = 'active');

  -- Authority path resolution
  if p_mandate_id is not null then
    perform public._assert_mandate_authorizes(
      p_mandate_id, p_group_id, v_actor_m, 'spend',
      p_amount, p_unit, p_resource_id
    );
    v_authority_path := 'mandate';
  elsif p_paid_by_membership_id = v_actor_m then
    v_authority_path := 'self_party';
  else
    v_authority_path := 'direct_permission';
  end if;

  -- Custom split validation
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

  -- Materializar obligations
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

  -- Memory event + sync rule evaluation
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
