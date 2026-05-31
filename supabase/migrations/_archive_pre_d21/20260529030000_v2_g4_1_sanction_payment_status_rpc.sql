-- V2-G4 sub-slice 1 — sanction payment status RPC
--
-- Surface read para "partial payments". El backend ya soporta partial
-- (record_settlement FIFO-allocates contra obligations; cuando una
-- obligation cae a 0 cascadea sanction → 'completed'). Falta visibilizar
-- en iOS: "Pendiente X de Y" + payment history.
--
-- Sin nuevos writes: lee group_sanctions → obligation_id → obligation +
-- settlement_obligations + group_settlements + profiles para hidratar
-- payments. Active-member gate.

CREATE OR REPLACE FUNCTION public.group_sanction_payment_status(
  p_sanction_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_sanction public.group_sanctions%ROWTYPE;
  v_obligation public.group_obligations%ROWTYPE;
  v_amount_original numeric;
  v_amount_outstanding numeric;
  v_amount_paid numeric;
  v_payments jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_sanction FROM public.group_sanctions WHERE id = p_sanction_id;
  IF v_sanction.id IS NULL THEN
    RAISE EXCEPTION 'sanction % not found', p_sanction_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_sanction.group_id
       AND gm.user_id = v_uid
       AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_sanction.group_id
      USING errcode = '42501';
  END IF;

  -- Linked obligation (las sanciones monetarias siempre tienen una;
  -- warning/repair_task no).
  IF v_sanction.obligation_id IS NOT NULL THEN
    SELECT * INTO v_obligation FROM public.group_obligations
     WHERE id = v_sanction.obligation_id;
  END IF;

  v_amount_original    := COALESCE(v_obligation.amount_original, v_sanction.amount, 0);
  v_amount_outstanding := COALESCE(v_obligation.amount_outstanding, v_sanction.amount, 0);
  v_amount_paid        := v_amount_original - v_amount_outstanding;

  -- Payment history: cada settlement_obligation tiene amount_closed
  -- contra esta obligation. Hidratamos paid_by + display_name del
  -- profile para que el sheet liste pagos legibles sin segundo hop.
  IF v_obligation.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'settlement_id',          gs.id,
        'amount_closed',          so.amount_closed,
        'paid_at',                gs.confirmed_at,
        'paid_by_membership_id',  gs.paid_by_membership_id,
        'paid_by_display_name',   p.display_name
      ) ORDER BY gs.confirmed_at DESC NULLS LAST), '[]'::jsonb)
      INTO v_payments
      FROM public.group_settlement_obligations so
      JOIN public.group_settlements gs ON gs.id = so.settlement_id
      LEFT JOIN public.group_memberships pm ON pm.id = gs.paid_by_membership_id
      LEFT JOIN public.profiles p ON p.id = pm.user_id
     WHERE so.obligation_id = v_obligation.id;
  END IF;

  RETURN jsonb_build_object(
    'sanction_id',         v_sanction.id,
    'amount_original',     v_amount_original,
    'amount_outstanding',  v_amount_outstanding,
    'amount_paid',         v_amount_paid,
    'unit',                COALESCE(v_obligation.unit, v_sanction.unit),
    'obligation_status',   COALESCE(v_obligation.status, 'no_obligation'),
    'sanction_status',     v_sanction.status,
    'payments',            v_payments
  );
END;
$$;

REVOKE ALL ON FUNCTION public.group_sanction_payment_status(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.group_sanction_payment_status(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_sanction_payment_status(uuid) IS
  'V2-G4.1: read RPC para sanction payment progress. Returns {amount_original, amount_outstanding, amount_paid, payments[]} hidratado para "Pendiente X de Y" + payment history. Active-member gate.';
