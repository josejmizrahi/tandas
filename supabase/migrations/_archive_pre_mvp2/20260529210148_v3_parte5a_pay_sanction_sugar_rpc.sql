-- V3 PARTE 5a — pay_sanction sugar RPC
--
-- Estado previo: para pagar una sanción había que llamar record_settlement
-- con 7-9 args (group_id, paid_by_membership, paid_to=NULL, paid_to_kind='pool',
-- amount, unit, notes, mandate_id, client_id). Ese ruido te obliga a saber
-- que las sanciones siempre van al pool y a resolver tu membership_id
-- antes de llamar.
--
-- pay_sanction es azúcar: caller pasa (sanction_id, amount, unit?, client_id?)
-- y la RPC resuelve target_membership, valida outstanding, y delega a
-- record_settlement. El FIFO interno de record_settlement cierra la
-- obligation y cascadea sanction.status → 'completed' cuando outstanding=0.
--
-- Authority (self-party only):
-- - Caller debe ser el target del sanction. Para pagar "on behalf" se usa
--   record_settlement directo con p_mandate_id (path mantiene su superficie).
-- Validaciones:
-- - amount > 0
-- - sanction.obligation_id NOT NULL (las warning/repair_task no son
--   monetarias y no se pagan con esta RPC)
-- - amount <= obligation.amount_outstanding (rechaza over-pay para evitar
--   ledger orphans documentados en handoff_money_v2_phase_6_wallet.md)

CREATE OR REPLACE FUNCTION public.pay_sanction(
  p_sanction_id uuid,
  p_amount numeric,
  p_unit text DEFAULT NULL,
  p_client_id text DEFAULT NULL
) RETURNS TABLE(settlement_id uuid, transaction_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_sanction public.group_sanctions%ROWTYPE;
  v_obligation public.group_obligations%ROWTYPE;
  v_target_membership uuid;
  v_unit text;
  v_settlement_id uuid;
  v_transaction_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be > 0' USING errcode = '22023';
  END IF;

  SELECT * INTO v_sanction FROM public.group_sanctions WHERE id = p_sanction_id;
  IF v_sanction.id IS NULL THEN
    RAISE EXCEPTION 'sanction % not found', p_sanction_id USING errcode = 'P0002';
  END IF;
  IF v_sanction.obligation_id IS NULL THEN
    RAISE EXCEPTION 'sanction has no monetary obligation (kind=%)', v_sanction.sanction_kind
      USING errcode = '22023';
  END IF;

  SELECT * INTO v_obligation FROM public.group_obligations WHERE id = v_sanction.obligation_id;
  IF v_obligation.amount_outstanding IS NULL OR v_obligation.amount_outstanding <= 0 THEN
    RAISE EXCEPTION 'sanction is already fully paid' USING errcode = '22023';
  END IF;
  IF p_amount > v_obligation.amount_outstanding THEN
    RAISE EXCEPTION 'amount % exceeds outstanding %', p_amount, v_obligation.amount_outstanding
      USING errcode = '22023';
  END IF;

  SELECT id INTO v_target_membership FROM public.group_memberships
   WHERE group_id = v_sanction.group_id AND user_id = v_uid AND status = 'active';
  IF v_target_membership IS NULL THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_sanction.group_id
      USING errcode = '42501';
  END IF;
  IF v_target_membership <> v_sanction.target_membership_id THEN
    RAISE EXCEPTION
      'only the target of the sanction can use pay_sanction (use record_settlement with p_mandate_id to pay on behalf)'
      USING errcode = '42501';
  END IF;

  v_unit := COALESCE(NULLIF(btrim(p_unit), ''), v_obligation.unit, v_sanction.unit, 'MXN');

  SELECT rs.settlement_id, rs.transaction_id
    INTO v_settlement_id, v_transaction_id
    FROM public.record_settlement(
      v_sanction.group_id,
      v_target_membership,
      NULL,        -- paid_to_membership_id (pool)
      'pool',      -- paid_to_kind
      p_amount,
      v_unit,
      'Pago de sanción ' || v_sanction.id::text,
      NULL,        -- mandate_id (self-party path)
      p_client_id
    ) AS rs;

  settlement_id := v_settlement_id;
  transaction_id := v_transaction_id;
  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.pay_sanction(uuid, numeric, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.pay_sanction(uuid, numeric, text, text) TO authenticated;

COMMENT ON FUNCTION public.pay_sanction(uuid, numeric, text, text) IS
  'V3 PARTE 5a: self-party sugar over record_settlement for sanction-derived obligations. Cap on outstanding (rejects over-pay). Mandate path remains via record_settlement directo.';
