-- V2-G4 sub-slice 2 — sanction payment plans MVP
--
-- Doctrina: el sancionado puede declarar un plan ("pago en 4 cuotas de
-- $250") para que el grupo sepa que el saldo va a entrar gradual y
-- no presione como si fuera mora. NO hay cron auto-debit (V3): el plan
-- es guía visual + tracking. El target sigue pagando vía record_settlement
-- normal; el plan solo reordena la narrativa.
--
-- Authority:
-- - propose: self_party (target del sanction). Auto-active al propose
--   (no requiere admin approval — el target acepta su propio plan).
--   Doctrina locked: dispute path sigue siendo paralelo (apelar la
--   sanction entera, no el plan).
-- - cancel: target_party O admin con sanction.review.
--
-- Constraint: UNIQUE (sanction_id) WHERE status = 'active' — un solo
-- plan vivo por sanción. Si se cancela, el target puede proponer otro.

CREATE TABLE IF NOT EXISTS public.group_sanction_payment_plans (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id                    uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  sanction_id                 uuid NOT NULL REFERENCES public.group_sanctions(id) ON DELETE CASCADE,
  proposed_by_membership_id   uuid NOT NULL REFERENCES public.group_memberships(id),
  total_amount                numeric(20,2) NOT NULL CHECK (total_amount > 0),
  installments                int NOT NULL CHECK (installments BETWEEN 2 AND 24),
  installment_amount          numeric(20,2) NOT NULL CHECK (installment_amount > 0),
  unit                        text NOT NULL,
  first_due_at                timestamptz NOT NULL,
  interval_days               int NOT NULL DEFAULT 30 CHECK (interval_days BETWEEN 1 AND 365),
  status                      text NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'completed', 'cancelled')),
  cancel_reason               text,
  notes                       text,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  cancelled_at                timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS one_active_plan_per_sanction
  ON public.group_sanction_payment_plans(sanction_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS group_sanction_payment_plans_by_group
  ON public.group_sanction_payment_plans(group_id, status);

ALTER TABLE public.group_sanction_payment_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS group_sanction_payment_plans_select ON public.group_sanction_payment_plans;
CREATE POLICY group_sanction_payment_plans_select
  ON public.group_sanction_payment_plans
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.group_memberships gm
       WHERE gm.group_id = group_sanction_payment_plans.group_id
         AND gm.user_id = auth.uid()
         AND gm.status = 'active'
    )
  );

-- ---------------------------------------------------------------------
-- propose_sanction_payment_plan(p_sanction_id, p_installments,
--   p_first_due_at, p_interval_days, p_notes) → uuid
-- self_party only (target of the sanction).

CREATE OR REPLACE FUNCTION public.propose_sanction_payment_plan(
  p_sanction_id   uuid,
  p_installments  int,
  p_first_due_at  timestamptz,
  p_interval_days int DEFAULT 30,
  p_notes         text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_sanction public.group_sanctions%ROWTYPE;
  v_target_membership public.group_memberships%ROWTYPE;
  v_obligation public.group_obligations%ROWTYPE;
  v_amount_outstanding numeric;
  v_installment_amount numeric;
  v_unit text;
  v_plan_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF p_installments IS NULL OR p_installments < 2 OR p_installments > 24 THEN
    RAISE EXCEPTION 'installments must be between 2 and 24' USING errcode = '22023';
  END IF;
  IF p_first_due_at IS NULL OR p_first_due_at < now() - interval '1 day' THEN
    RAISE EXCEPTION 'first_due_at must be in the present or future' USING errcode = '22023';
  END IF;
  IF p_interval_days IS NULL OR p_interval_days < 1 OR p_interval_days > 365 THEN
    RAISE EXCEPTION 'interval_days must be between 1 and 365' USING errcode = '22023';
  END IF;

  SELECT * INTO v_sanction FROM public.group_sanctions WHERE id = p_sanction_id;
  IF v_sanction.id IS NULL THEN
    RAISE EXCEPTION 'sanction % not found', p_sanction_id;
  END IF;

  -- Self-party: actor must be the target of the sanction.
  SELECT * INTO v_target_membership
    FROM public.group_memberships
   WHERE id = v_sanction.target_membership_id;
  IF v_target_membership.user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'only the target of the sanction can propose a payment plan'
      USING errcode = '42501';
  END IF;

  IF v_sanction.obligation_id IS NULL THEN
    RAISE EXCEPTION 'sanction has no monetary obligation' USING errcode = '22023';
  END IF;
  SELECT * INTO v_obligation FROM public.group_obligations
   WHERE id = v_sanction.obligation_id;
  v_amount_outstanding := COALESCE(v_obligation.amount_outstanding, 0);
  IF v_amount_outstanding <= 0 THEN
    RAISE EXCEPTION 'sanction is already fully paid' USING errcode = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.group_sanction_payment_plans
     WHERE sanction_id = p_sanction_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'sanction already has an active payment plan' USING errcode = '23505';
  END IF;

  v_unit := COALESCE(v_obligation.unit, v_sanction.unit, 'MXN');
  -- round to 2 decimals; last installment absorbs the remainder via
  -- iOS display (no need to track separately at DB level).
  v_installment_amount := round(v_amount_outstanding / p_installments, 2);

  INSERT INTO public.group_sanction_payment_plans (
    group_id, sanction_id, proposed_by_membership_id,
    total_amount, installments, installment_amount, unit,
    first_due_at, interval_days, status, notes
  ) VALUES (
    v_sanction.group_id, p_sanction_id, v_target_membership.id,
    v_amount_outstanding, p_installments, v_installment_amount, v_unit,
    p_first_due_at, p_interval_days, 'active', p_notes
  ) RETURNING id INTO v_plan_id;

  PERFORM public.record_system_event(
    p_group_id    => v_sanction.group_id,
    p_event_type  => 'sanction.payment_plan_proposed',
    p_entity_kind => 'sanction',
    p_entity_id   => p_sanction_id,
    p_payload     => jsonb_build_object(
      'plan_id',         v_plan_id,
      'sanction_id',     p_sanction_id,
      'installments',    p_installments,
      'total_amount',    v_amount_outstanding,
      'first_due_at',    p_first_due_at,
      'interval_days',   p_interval_days
    )
  );

  RETURN v_plan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- cancel_sanction_payment_plan(p_plan_id, p_reason) → void
-- target OR admin with sanction.review.

CREATE OR REPLACE FUNCTION public.cancel_sanction_payment_plan(
  p_plan_id uuid,
  p_reason  text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_plan public.group_sanction_payment_plans%ROWTYPE;
  v_target_user uuid;
  v_is_target boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_plan FROM public.group_sanction_payment_plans WHERE id = p_plan_id;
  IF v_plan.id IS NULL THEN
    RAISE EXCEPTION 'plan % not found', p_plan_id;
  END IF;
  IF v_plan.status <> 'active' THEN
    RAISE EXCEPTION 'plan % is not active', p_plan_id USING errcode = '22023';
  END IF;

  SELECT user_id INTO v_target_user
    FROM public.group_memberships
   WHERE id = v_plan.proposed_by_membership_id;
  v_is_target := (v_target_user = v_uid);

  IF NOT v_is_target THEN
    PERFORM public.assert_permission(v_plan.group_id, 'sanction.review');
  END IF;

  UPDATE public.group_sanction_payment_plans
     SET status        = 'cancelled',
         cancel_reason = p_reason,
         cancelled_at  = now()
   WHERE id = p_plan_id;

  PERFORM public.record_system_event(
    p_group_id    => v_plan.group_id,
    p_event_type  => 'sanction.payment_plan_cancelled',
    p_entity_kind => 'sanction',
    p_entity_id   => v_plan.sanction_id,
    p_payload     => jsonb_build_object(
      'plan_id',  p_plan_id,
      'reason',   p_reason,
      'by_target', v_is_target
    )
  );
END;
$$;

-- ---------------------------------------------------------------------
-- group_sanction_payment_plan_active(p_sanction_id) → jsonb
-- Read RPC. Returns the single active plan (or null) hydrated with
-- next_due_at + installments_paid (derived from existing settlement
-- coverage). Active-member gate.

CREATE OR REPLACE FUNCTION public.group_sanction_payment_plan_active(
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
  v_plan public.group_sanction_payment_plans%ROWTYPE;
  v_amount_paid numeric := 0;
  v_amount_outstanding numeric := 0;
  v_installments_paid int;
  v_next_due_at timestamptz;
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

  SELECT * INTO v_plan
    FROM public.group_sanction_payment_plans
   WHERE sanction_id = p_sanction_id AND status = 'active'
   LIMIT 1;

  IF v_plan.id IS NULL THEN
    RETURN jsonb_build_object('active', false);
  END IF;

  -- installments_paid = floor(amount_paid / installment_amount). Uses
  -- current obligation outstanding to derive.
  IF v_sanction.obligation_id IS NOT NULL THEN
    SELECT COALESCE(amount_original - amount_outstanding, 0),
           COALESCE(amount_outstanding, 0)
      INTO v_amount_paid, v_amount_outstanding
      FROM public.group_obligations
     WHERE id = v_sanction.obligation_id;
  END IF;

  v_installments_paid := LEAST(
    v_plan.installments,
    GREATEST(0, FLOOR(v_amount_paid / v_plan.installment_amount)::int)
  );
  v_next_due_at := v_plan.first_due_at
    + (v_installments_paid * v_plan.interval_days || ' days')::interval;

  RETURN jsonb_build_object(
    'active',                  true,
    'plan_id',                 v_plan.id,
    'sanction_id',             v_plan.sanction_id,
    'total_amount',            v_plan.total_amount,
    'installments',            v_plan.installments,
    'installment_amount',      v_plan.installment_amount,
    'unit',                    v_plan.unit,
    'first_due_at',            v_plan.first_due_at,
    'interval_days',           v_plan.interval_days,
    'notes',                   v_plan.notes,
    'created_at',              v_plan.created_at,
    'amount_paid',             v_amount_paid,
    'amount_outstanding',      v_amount_outstanding,
    'installments_paid',       v_installments_paid,
    'next_due_at',             CASE WHEN v_installments_paid >= v_plan.installments
                                    THEN NULL ELSE v_next_due_at END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.propose_sanction_payment_plan(uuid, int, timestamptz, int, text) FROM public;
REVOKE ALL ON FUNCTION public.cancel_sanction_payment_plan(uuid, text) FROM public;
REVOKE ALL ON FUNCTION public.group_sanction_payment_plan_active(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.propose_sanction_payment_plan(uuid, int, timestamptz, int, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_sanction_payment_plan(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_sanction_payment_plan_active(uuid) TO authenticated;

COMMENT ON TABLE public.group_sanction_payment_plans IS
  'V2-G4.2: payment plans declared by the sanction target. No auto-debit cron — plan is narrative + tracking. Target pays normally via record_settlement; plan helps the group read progress as on-schedule vs in-arrears. Cron auto-debit deferred to V3.';
