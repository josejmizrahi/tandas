drop function if exists public.record_contribution(uuid, uuid, numeric, text, uuid, text, boolean, text);

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
  perform public.assert_permission(p_group_id, 'contribution.record');
  if p_amount is null or p_amount <= 0 then raise exception 'amount required'; end if;

  if p_client_id is not null then
    select id into v_tx_id from public.group_resource_transactions
     where group_id = p_group_id and client_id = p_client_id;
    if v_tx_id is not null then return v_tx_id; end if;
  end if;

  v_actor_m := (select id from public.group_memberships
                where group_id = p_group_id and user_id = auth.uid() and status = 'active');

  if p_mandate_id is not null then
    perform public._assert_mandate_authorizes(
      p_mandate_id, p_group_id, v_actor_m, 'contribute',
      p_amount, p_unit, p_resource_id
    );
    v_authority_path := 'mandate';
  elsif p_from_membership_id = v_actor_m or p_from_membership_id is null then
    v_authority_path := 'self_party';
  else
    v_authority_path := 'direct_permission';
  end if;

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
