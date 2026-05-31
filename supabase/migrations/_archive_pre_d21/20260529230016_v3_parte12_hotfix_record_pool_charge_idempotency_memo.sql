-- PARTE 12 hot-fix #6: record_pool_charge declaraba p_client_id pero lo guardaba
-- en metadata->>'client_id' (jsonb), NO en una column con UNIQUE. Resultado:
-- cualquier retry insertaba nueva obligation → double-charging silente.
--
-- Hot-fix: memo check via metadata->>'client_id' al inicio. Si match, retorna
-- el id existente.

CREATE OR REPLACE FUNCTION public.record_pool_charge(
  p_group_id uuid, p_target_membership_id uuid, p_amount numeric, p_unit text,
  p_charge_kind text,
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
  v_id             uuid;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
begin
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_charge_kind not in ('quota','buy_in','fee') then raise exception 'invalid charge_kind'; end if;

  if p_client_id is not null then
    select o.id into v_id from public.group_obligations o
     where o.group_id = p_group_id
       and o.obligation_kind = 'pool_charge'
       and (o.metadata->>'client_id') = p_client_id;
    if v_id is not null then return v_id; end if;
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
$function$;

REVOKE ALL ON FUNCTION public.record_pool_charge(uuid,uuid,numeric,text,text,text,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_pool_charge(uuid,uuid,numeric,text,text,text,uuid,text) TO authenticated, service_role;
