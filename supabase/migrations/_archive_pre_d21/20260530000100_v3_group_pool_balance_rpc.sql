-- V3 — group_pool_balance read RPC
--
-- Surface el balance acumulado del fondo común del grupo. Doctrina
-- doctrine_shared_money: el pool por default crece via contributions
-- + multas (settlement_payments to pool); decrece via payouts. Los
-- gastos individuales (expense rows) NO tocan el pool en el modelo
-- canonical — se materializan como peer-to-peer obligations vía
-- split_breakdown.
--
-- Active-member gate idéntico a las demás read RPCs.

CREATE OR REPLACE FUNCTION public.group_pool_balance(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_contributions_in  numeric := 0;
  v_settlements_in    numeric := 0;
  v_payouts_out       numeric := 0;
  v_reversals_net     numeric := 0;
  v_net               numeric := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id = v_uid
       AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_contributions_in
    FROM public.group_resource_transactions
   WHERE group_id = p_group_id
     AND transaction_type = 'contribution'
     AND to_membership_id IS NULL;

  SELECT COALESCE(SUM(amount), 0) INTO v_settlements_in
    FROM public.group_resource_transactions
   WHERE group_id = p_group_id
     AND transaction_type = 'settlement_payment'
     AND to_membership_id IS NULL;

  SELECT COALESCE(SUM(amount), 0) INTO v_payouts_out
    FROM public.group_resource_transactions
   WHERE group_id = p_group_id
     AND transaction_type = 'payout'
     AND from_membership_id IS NULL;

  SELECT COALESCE(SUM(amount * CASE
    WHEN to_membership_id IS NULL THEN -1
    WHEN from_membership_id IS NULL THEN 1
    ELSE 0
  END), 0) INTO v_reversals_net
    FROM public.group_resource_transactions
   WHERE group_id = p_group_id
     AND transaction_type = 'reversal';

  v_net := v_contributions_in + v_settlements_in - v_payouts_out + v_reversals_net;

  RETURN jsonb_build_object(
    'group_id',          p_group_id,
    'contributions_in',  v_contributions_in,
    'settlements_in',    v_settlements_in,
    'payouts_out',       v_payouts_out,
    'reversals_net',     v_reversals_net,
    'net',               v_net,
    'unit',              'MXN'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.group_pool_balance(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.group_pool_balance(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_pool_balance(uuid) IS
  'V3: pool balance del grupo = contributions + settlements_to_pool - payouts + reversals_net. Active-member gate.';
