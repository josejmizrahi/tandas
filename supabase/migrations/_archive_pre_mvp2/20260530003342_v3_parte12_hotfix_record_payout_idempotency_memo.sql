-- PARTE 12 hot-fix #5: record_payout declaraba p_client_id, lo guardaba en
-- group_resource_transactions.client_id (UNIQUE en (group_id, client_id)),
-- pero NO hacía memo check al inicio. Resultado: en retry el client recibe
-- unique_violation error en vez del transaction_id existente — no es idempotent.
--
-- Pattern canonical (de record_contribution): SELECT por (group_id, client_id)
-- al inicio; si existe retornar el id existente.

CREATE OR REPLACE FUNCTION public.record_payout(
  p_group_id uuid, p_to_membership_id uuid, p_amount numeric, p_unit text,
  p_source_resource_id uuid DEFAULT NULL::uuid,
  p_reason text DEFAULT NULL::text,
  p_mandate_id uuid DEFAULT NULL::uuid,
  p_client_id text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_tx             uuid;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
begin
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  -- PARTE 12 hot-fix: memo check antes de actuar.
  if p_client_id is not null then
    select grt.id into v_tx from public.group_resource_transactions grt
     where grt.group_id = p_group_id and grt.client_id = p_client_id;
    if v_tx is not null then return v_tx; end if;
  end if;

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
$function$;

REVOKE ALL ON FUNCTION public.record_payout(uuid,uuid,numeric,text,uuid,text,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_payout(uuid,uuid,numeric,text,uuid,text,uuid,text) TO authenticated, service_role;
