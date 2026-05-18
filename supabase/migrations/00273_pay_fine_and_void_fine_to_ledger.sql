-- 00273_pay_fine_and_void_fine_to_ledger.sql
--
-- Sprint 1.1 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F1 (HERESY): pay_fine references columns dropped in mig 00078
--   (groups.fund_balance, groups.fund_enabled) AND fines.paid/paid_at/paid_to_fund
--   (none exist in current schema). Function fails at runtime on any call.
--
-- Finding F1.b: void_fine equally references fines.status / waived / waived_at /
--   waived_reason (all dropped). Function fails at runtime on any call.
--
-- Doctrine restored:
-- - Pay/void status derives from ledger_entries via fines_view projection.
-- - pay_fine emits ledger_entries(type='fine_paid'). void_fine emits 'fine_voided'.
-- - Pattern matches officialize_fine (mig 00148) which is already ledger-clean.
-- - No reads/writes to groups.fund_balance/fund_enabled or fines.paid/status.
-- - Idempotent: existing fine_paid/fine_voided ledger entry short-circuits.
-- - pay_fine preserves void return type (CREATE OR REPLACE safe).
-- - void_fine preserves public.fines return type + p_reason DEFAULT NULL.

CREATE OR REPLACE FUNCTION public.pay_fine(p_fine_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  f public.fines;
  uid uuid := auth.uid();
  v_member_id uuid;
  v_has_paid boolean;
  v_has_voided boolean;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO f FROM public.fines WHERE id = p_fine_id FOR UPDATE;
  IF f.id IS NULL THEN
    RAISE EXCEPTION 'fine not found';
  END IF;

  -- Permission gate: caller is the fined member OR has markFinePaid permission.
  IF NOT (f.user_id = uid
          OR public.has_permission(f.group_id, uid, 'markFinePaid')) THEN
    RAISE EXCEPTION 'not allowed' USING errcode = '42501';
  END IF;

  -- A voided fine cannot be paid.
  SELECT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_voided'
       AND (le.metadata->>'fine_id')::uuid = f.id
  ) INTO v_has_voided;
  IF v_has_voided THEN
    RAISE EXCEPTION 'cannot pay a voided fine';
  END IF;

  -- Idempotent: if already paid, exit silently.
  SELECT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_paid'
       AND (le.metadata->>'fine_id')::uuid = f.id
  ) INTO v_has_paid;
  IF v_has_paid THEN
    RETURN;
  END IF;

  -- Resolve member_id of the fined user (may be NULL if member was removed).
  SELECT id INTO v_member_id
    FROM public.group_members
   WHERE group_id = f.group_id AND user_id = f.user_id
   LIMIT 1;

  -- Emit the canonical fine_paid atom.
  -- Pattern mirrors officialize_fine (mig 00148):
  --   from_member_id = fined member (money leaves them)
  --   to_member_id   = null (paid into the group — routing to a specific fund is
  --                          a downstream concern handled by future fund-routing rules)
  --   resource_id    = the resource the fine is attached to (event, etc.)
  --   currency       = 'MXN' to match officialize_fine; cross-RPC currency
  --                    unification is a separate cleanup item
  INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
  ) VALUES (
    f.group_id,
    f.resource_id,
    'fine_paid',
    (f.amount * 100)::bigint,
    'MXN',
    v_member_id,
    NULL,
    jsonb_build_object(
      'fine_id', f.id,
      'rule_id', f.rule_id,
      'via',     'pay_fine_rpc'
    ),
    now(), now(), uid
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.void_fine(p_fine_id uuid, p_reason text DEFAULT NULL)
RETURNS public.fines
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  f public.fines;
  uid uuid := auth.uid();
  v_member_id uuid;
  v_has_paid boolean;
  v_has_voided boolean;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO f FROM public.fines WHERE id = p_fine_id FOR UPDATE;
  IF f.id IS NULL THEN
    RAISE EXCEPTION 'fine not found';
  END IF;

  IF NOT public.has_permission(f.group_id, uid, 'voidFine') THEN
    RAISE EXCEPTION 'voidFine permission required' USING errcode = '42501';
  END IF;

  IF length(coalesce(p_reason, '')) < 2 THEN
    RAISE EXCEPTION 'reason required';
  END IF;

  -- A paid fine cannot be voided. (Previously enforced by status='proposed/officialized';
  -- now derived from absence of fine_paid ledger entry.)
  SELECT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_paid'
       AND (le.metadata->>'fine_id')::uuid = f.id
  ) INTO v_has_paid;
  IF v_has_paid THEN
    RAISE EXCEPTION 'cannot void a paid fine';
  END IF;

  -- Idempotent: if already voided, return current fine row.
  SELECT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_voided'
       AND (le.metadata->>'fine_id')::uuid = f.id
  ) INTO v_has_voided;
  IF v_has_voided THEN
    RETURN f;
  END IF;

  -- Resolve member_id of the fined user.
  SELECT id INTO v_member_id
    FROM public.group_members
   WHERE group_id = f.group_id AND user_id = f.user_id
   LIMIT 1;

  -- Emit the canonical fine_voided atom.
  -- to_member_id = fined member: the obligation is being cleared in their favor,
  -- mirroring the symmetric inverse of fine_officialized (which puts obligation
  -- ON the member via from_member_id).
  INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
  ) VALUES (
    f.group_id,
    f.resource_id,
    'fine_voided',
    (f.amount * 100)::bigint,
    'MXN',
    NULL,
    v_member_id,
    jsonb_build_object(
      'fine_id',           f.id,
      'rule_id',           f.rule_id,
      'reason',            p_reason,
      'voided_by_user_id', uid,
      'via',               'void_fine_rpc'
    ),
    now(), now(), uid
  );

  -- Inbox notification to the fined member (preserved from original void_fine).
  INSERT INTO public.user_actions (
    user_id, group_id, action_type, reference_id,
    title, body, priority
  ) VALUES (
    f.user_id, f.group_id, 'fineVoided', f.id,
    'Multa anulada por admin: $' || trim(to_char(f.amount, 'FM999G999D00')),
    p_reason,
    'low'
  );

  -- system_event for activity feed + downstream rule engine (preserved).
  PERFORM public.record_system_event(
    f.group_id,
    'fineVoided',
    f.id,
    NULL,
    jsonb_build_object(
      'amount',            f.amount,
      'reason',            p_reason,
      'voided_by_user_id', uid
    )
  );

  RETURN f;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.pay_fine(uuid)            FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.pay_fine(uuid)            TO authenticated;
REVOKE EXECUTE ON FUNCTION public.void_fine(uuid, text)     FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.void_fine(uuid, text)     TO authenticated;

COMMENT ON FUNCTION public.pay_fine(uuid) IS
  'Sprint 1.1 doctrinal fix (mig 00273) per ConsistencyAudit_2026-05-17 F1. Emits ledger_entries(type=fine_paid). Drops refs to dropped groups.fund_balance/fund_enabled columns. Idempotent on existing fine_paid entry. Status derives via fines_view.';

COMMENT ON FUNCTION public.void_fine(uuid, text) IS
  'Sprint 1.1 doctrinal fix (mig 00273) per ConsistencyAudit_2026-05-17 F1. Emits ledger_entries(type=fine_voided) + user_action + fineVoided system_event. Drops refs to dropped fines.status/waived* columns. Idempotent. Cannot void paid fines.';
