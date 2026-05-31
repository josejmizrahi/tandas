-- Fase D follow-up: record_pool_charge ahora acepta p_resource_id
-- (opcional) y lo persiste como source_resource_id en la obligation.
-- record_settlement ya propaga ese campo a la transaction al cerrar
-- la obligation, asi que la cadena completa charge→settlement→ledger
-- queda linkeada al recurso sin tocar settlement.

DROP FUNCTION IF EXISTS public.record_pool_charge(uuid, uuid, numeric, text, text, text, uuid, text);

CREATE OR REPLACE FUNCTION public.record_pool_charge(
  p_group_id              uuid,
  p_target_membership_id  uuid,
  p_amount                numeric,
  p_unit                  text,
  p_charge_kind           text,
  p_reason                text DEFAULT NULL,
  p_mandate_id            uuid DEFAULT NULL,
  p_client_id             text DEFAULT NULL,
  p_resource_id           uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_id             uuid;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
  v_resource_group uuid;
BEGIN
  IF p_amount <= 0 THEN RAISE EXCEPTION 'amount must be positive'; END IF;
  IF p_charge_kind NOT IN ('quota','buy_in','fee') THEN RAISE EXCEPTION 'invalid charge_kind'; END IF;

  IF p_resource_id IS NOT NULL THEN
    SELECT group_id INTO v_resource_group FROM public.group_resources WHERE id = p_resource_id;
    IF v_resource_group IS NULL THEN
      RAISE EXCEPTION 'resource not found' USING errcode = '22023';
    END IF;
    IF v_resource_group <> p_group_id THEN
      RAISE EXCEPTION 'resource is not in this group' USING errcode = '22023';
    END IF;
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT o.id INTO v_id FROM public.group_obligations o
     WHERE o.group_id = p_group_id
       AND o.obligation_kind = 'pool_charge'
       AND (o.metadata->>'client_id') = p_client_id;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  v_actor_m := (SELECT gm.id FROM public.group_memberships gm
                WHERE gm.group_id = p_group_id AND gm.user_id = auth.uid() AND gm.status = 'active');
  IF v_actor_m IS NULL THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id;
  END IF;

  v_authority_path := public._resolve_authority_path(
    p_group_id         => p_group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => false,
    p_mandate_id       => p_mandate_id,
    p_permission       => 'pool_charge.record',
    p_mandate_scope    => 'charge',
    p_amount           => p_amount,
    p_unit             => p_unit,
    p_resource_id      => p_resource_id
  );

  INSERT INTO public.group_obligations (
    group_id, owed_by_membership_id, owed_to_kind,
    obligation_kind, amount_original, amount_outstanding, unit,
    description, source_mandate_id, metadata, source_resource_id
  ) VALUES (
    p_group_id, p_target_membership_id, 'pool',
    'pool_charge', p_amount, p_amount, p_unit,
    p_reason, p_mandate_id,
    jsonb_build_object('charge_kind', p_charge_kind, 'client_id', p_client_id),
    p_resource_id
  ) RETURNING id INTO v_id;

  SELECT rse.uuid_id INTO v_event_uuid FROM public.record_system_event(
    p_group_id, 'money.pool_charge_created', 'obligation', v_id, p_reason,
    jsonb_build_object(
      'amount', p_amount,
      'unit', p_unit,
      'kind', p_charge_kind,
      'target', p_target_membership_id,
      'resource_id', p_resource_id,
      'authority_path', v_authority_path,
      'mandate_id', p_mandate_id
    )
  ) rse;
  PERFORM public.evaluate_rules_for_event(v_event_uuid, 'sync');

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_pool_charge(uuid, uuid, numeric, text, text, text, uuid, text, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.record_pool_charge(uuid, uuid, numeric, text, text, text, uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.record_pool_charge(uuid, uuid, numeric, text, text, text, uuid, text, uuid) IS
'Records a pool charge. p_resource_id optional: cuando se da, la obligation queda con source_resource_id, y record_settlement la propagara al ledger entry. Idempotent via p_client_id en metadata.';
