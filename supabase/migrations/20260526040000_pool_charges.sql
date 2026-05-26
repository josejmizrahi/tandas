-- 20260526040000 — pool_charges (Money 2.0 Phase 4.4).
--
-- Founder ask 2026-05-26: "agregar una forma de meter al fondo del
-- grupo una obligación de un miembro. Por ejemplo, en mis cenas
-- jugamos poker. Cada quien mete x dinero al fondo y después de jugar
-- ese dinero se reparte al ganador."
--
-- Generalización: cualquier deuda recurrente o puntual member→pool —
-- buy-in de poker, cuota mensual, aportación de tanda, contribución
-- para un viaje — necesita el mismo primitivo: "Juan debe meter $X al
-- fondo, queda pendiente hasta que pague".
--
-- Hoy SOLO las multas (Phase 4.3) producen obligaciones member→pool
-- vía `obligations.owed_to_member_id = NULL`. El patrón existe pero
-- está reservado al flujo punitivo. Esta migración lo abre como
-- primitivo genérico.
--
-- Arquitectura (delta sobre Phase 4.1-4.3)
-- =========================================
--
--   obligations.kind      ← clasifica el origen
--     'peer'              ← obligación member→member (expense split)
--     'fine'              ← multa (member→pool, punitiva)
--     'pool_charge'       ← cuota / buy-in / aportación esperada
--                            (member→pool, NO punitiva)
--
--   obligations.client_id ← idempotencia (batch issue)
--   obligations.due_at    ← fecha límite opcional
--
-- Flujo
-- =====
--   1. Issuance:
--        `issue_pool_charges(group, [debtors], amount, currency,
--                            reason, due_at?, source_resource?, client_id)`
--      → inserta N obligations con kind='pool_charge', owed_to=NULL,
--        status='open'. Un solo client_id por batch (idempotente).
--
--   2. Payment:
--        `pay_pool_charge(obligation_id, paid_by_member?, note?, client_id?)`
--      → inserta un ledger_entry type='contribution' (cash flow real al
--        pool) + UPDATE obligation.status='settled'. Para el caso poker:
--        después de que todos pagan, el ganador recibe via `record_payout`.
--
--   3. Void (admin / quien registró):
--        `void_pool_charge(obligation_id, reason?)`
--      → status='voided'. Se anula sin tocar el ledger.
--
-- Vista downstream
-- ================
-- `member_obligations_view` extiende `obligation_cents` para incluir
-- pool charges activos. Net effect: si Juan tiene $500 de cuota
-- pendiente, su `net_peer_position_cents` baja $500 → el UI dice
-- "Debes $500 al pool" en lugar de "Estás al día".
--
-- Decisión consciente sobre stake
-- ===============================
-- Pagar un pool_charge emite un `contribution` ledger entry, igual que
-- aportar voluntariamente. Esto significa que el stake del miembro
-- crece (correcto para tandas/cuotas, donde el dinero ES capital).
-- Para el caso poker (buy-in que se va a pagar al ganador), el stake
-- queda "inflado" hasta que el ganador recibe su payout. No es
-- contabilidad incorrecta — es la asimetría real (puse $500, recibí $0
-- de vuelta, perdí). Future: una variante `pool_charge_paid` ledger
-- type podría separar buy-ins de capital, pero V1 lo mantiene simple.

-- ===========================================================================
-- 1. Schema delta
-- ===========================================================================

ALTER TABLE public.obligations
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'peer';

ALTER TABLE public.obligations
  ADD COLUMN IF NOT EXISTS client_id uuid;

ALTER TABLE public.obligations
  ADD COLUMN IF NOT EXISTS due_at timestamptz;

-- Drop + recreate the check so we can add the kind values atomically.
ALTER TABLE public.obligations
  DROP CONSTRAINT IF EXISTS obligations_kind_check;

ALTER TABLE public.obligations
  ADD CONSTRAINT obligations_kind_check
  CHECK (kind IN ('peer', 'fine', 'pool_charge'));

-- Partial unique index for client-id idempotency on issuance.
CREATE UNIQUE INDEX IF NOT EXISTS obligations_client_id_unique
  ON public.obligations(group_id, client_id)
  WHERE client_id IS NOT NULL;

-- Index for the new "active pool charges per group" surface.
CREATE INDEX IF NOT EXISTS idx_obligations_group_kind_status
  ON public.obligations(group_id, kind, status);

-- ===========================================================================
-- 2. Backfill existing rows
-- ===========================================================================

-- Peer obligations (split-breakdown materializations).
UPDATE public.obligations
   SET kind = 'peer'
 WHERE kind = 'peer'           -- the default already set it; idempotent
   AND owed_to_member_id IS NOT NULL;

-- Fine obligations (Phase 4.3 trigger materializations).
UPDATE public.obligations
   SET kind = 'fine'
 WHERE owed_to_member_id IS NULL
   AND (metadata ? 'fine_id')
   AND kind <> 'fine';

-- ===========================================================================
-- 3. RPC: issue_pool_charges
-- ===========================================================================
-- Bulk-issues N obligations in one shot. Designed for the poker /
-- cuota batch use case where the user picks all debtors and a flat
-- amount once. Atomic — either every row lands or none does.
--
-- Idempotency: a single client_id maps to the whole batch. Re-issuing
-- with the same (group_id, client_id) returns the rows already
-- inserted, never duplicates.
--
-- The function is SECURITY DEFINER but checks the caller is an active
-- group member before any writes. Both the caller and each debtor
-- must belong to the group.

CREATE OR REPLACE FUNCTION public.issue_pool_charges(
  p_group_id            uuid,
  p_debtor_member_ids   uuid[],
  p_amount_cents        bigint,
  p_currency            text DEFAULT NULL,
  p_reason              text DEFAULT NULL,
  p_due_at              timestamptz DEFAULT NULL,
  p_source_resource_id  uuid DEFAULT NULL,
  p_client_id           uuid DEFAULT NULL
)
RETURNS SETOF public.obligations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid             uuid := auth.uid();
  v_caller_member   uuid;
  v_currency        text;
  v_group_currency  text;
  v_reason          text;
  v_debtor          uuid;
  v_inserted_any    boolean := false;
BEGIN
  -- Auth + arg validation.
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'issue_pool_charges: auth required' USING errcode = '42501';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'issue_pool_charges: group_id required' USING errcode = '22023';
  END IF;
  IF p_debtor_member_ids IS NULL OR array_length(p_debtor_member_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'issue_pool_charges: at least one debtor required' USING errcode = '22023';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'issue_pool_charges: amount must be positive' USING errcode = '22023';
  END IF;

  -- Caller must be an active member of the group.
  SELECT gm.id INTO v_caller_member
    FROM public.group_members gm
   WHERE gm.group_id = p_group_id AND gm.user_id = v_uid AND gm.active
   LIMIT 1;
  IF v_caller_member IS NULL THEN
    RAISE EXCEPTION 'issue_pool_charges: caller not an active member of group'
      USING errcode = '42501';
  END IF;

  -- Idempotency pre-check: if any row with this client_id exists,
  -- return ALL rows from that batch (one client_id = one batch).
  IF p_client_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.obligations
       WHERE group_id = p_group_id AND client_id = p_client_id
    ) THEN
      RETURN QUERY
        SELECT * FROM public.obligations
         WHERE group_id = p_group_id AND client_id = p_client_id
         ORDER BY created_at ASC;
      RETURN;
    END IF;
  END IF;

  -- Validate every debtor belongs to the group (active OR inactive — a
  -- charge can be issued to someone who later goes inactive).
  FOREACH v_debtor IN ARRAY p_debtor_member_ids LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.group_members gm
       WHERE gm.id = v_debtor AND gm.group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'issue_pool_charges: debtor % not in group', v_debtor
        USING errcode = '22023';
    END IF;
  END LOOP;

  -- Optional resource scope must belong to the group.
  IF p_source_resource_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.resources r
       WHERE r.id = p_source_resource_id AND r.group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'issue_pool_charges: source_resource does not belong to group'
        USING errcode = '22023';
    END IF;
  END IF;

  -- Resolve currency.
  SELECT g.currency INTO v_group_currency FROM public.groups g WHERE g.id = p_group_id;
  v_currency := COALESCE(p_currency, v_group_currency, 'MXN');

  v_reason := NULLIF(trim(coalesce(p_reason, '')), '');

  -- Insert one obligation per debtor. Same client_id stamped on all so
  -- a retry returns the whole batch via the idempotency pre-check.
  RETURN QUERY
  INSERT INTO public.obligations (
    group_id, source_movement_id, owed_by_member_id, owed_to_member_id,
    amount_cents, currency, status, source_resource_id, metadata,
    kind, client_id, due_at, created_at, updated_at
  )
  SELECT
    p_group_id,
    NULL,
    debtor,
    NULL,                                  -- owed to the group/pool
    p_amount_cents,
    v_currency,
    'open',
    p_source_resource_id,
    jsonb_build_object(
      'kind',   'pool_charge',
      'reason', v_reason,
      'issued_by', v_uid::text
    ),
    'pool_charge',
    p_client_id,
    p_due_at,
    now(),
    now()
  FROM unnest(p_debtor_member_ids) AS debtor
  RETURNING *;

EXCEPTION WHEN unique_violation THEN
  -- Race: concurrent batch with same client_id won. Re-read.
  IF p_client_id IS NOT NULL THEN
    RETURN QUERY
      SELECT * FROM public.obligations
       WHERE group_id = p_group_id AND client_id = p_client_id
       ORDER BY created_at ASC;
    RETURN;
  END IF;
  RAISE;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.issue_pool_charges(uuid, uuid[], bigint, text, text, timestamptz, uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.issue_pool_charges(uuid, uuid[], bigint, text, text, timestamptz, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.issue_pool_charges(uuid, uuid[], bigint, text, text, timestamptz, uuid, uuid) IS
  'Money 2.0 Phase 4.4 (mig 20260526040000): batch-issue pool charges (cuotas / buy-ins / aportaciones esperadas) to N debtors with one flat amount. Returns the inserted obligations. Idempotent via (group_id, p_client_id) — same client_id returns the full original batch.';

-- ===========================================================================
-- 4. RPC: pay_pool_charge
-- ===========================================================================
-- Closes a single pool charge by emitting a contribution ledger entry
-- (cash inflow to the pool) and marking the obligation settled. The
-- two writes are atomic in the function's transaction.
--
-- Auth: any active group member can call. The debtor (owed_by_member)
-- typically pays for themselves, but a third party can pay on their
-- behalf via `p_paid_by_member_id` (tri-role: paid_by ≠ owed_by).
-- This matches the doctrine_ledger_tri_role memory: paid_by goes in
-- ledger metadata; the obligation's owed_by stays as the originally
-- charged member.

CREATE OR REPLACE FUNCTION public.pay_pool_charge(
  p_obligation_id       uuid,
  p_paid_by_member_id   uuid DEFAULT NULL,
  p_note                text DEFAULT NULL,
  p_client_id           uuid DEFAULT NULL
)
RETURNS public.ledger_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid           uuid := auth.uid();
  v_obligation    public.obligations;
  v_caller_member uuid;
  v_payer         uuid;
  v_note          text;
  v_ledger        public.ledger_entries;
  v_existing      public.ledger_entries;
  v_metadata      jsonb;
  v_outstanding   bigint;
  v_applied       bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'pay_pool_charge: auth required' USING errcode = '42501';
  END IF;
  IF p_obligation_id IS NULL THEN
    RAISE EXCEPTION 'pay_pool_charge: obligation_id required' USING errcode = '22023';
  END IF;

  -- Lock the obligation row so concurrent pay/void don't race.
  SELECT * INTO v_obligation
    FROM public.obligations
   WHERE id = p_obligation_id
   FOR UPDATE;
  IF v_obligation.id IS NULL THEN
    RAISE EXCEPTION 'pay_pool_charge: obligation not found' USING errcode = '22023';
  END IF;
  IF v_obligation.kind <> 'pool_charge' THEN
    RAISE EXCEPTION 'pay_pool_charge: obligation is not a pool charge (kind=%)', v_obligation.kind
      USING errcode = '22023';
  END IF;
  IF v_obligation.status NOT IN ('open', 'partially_paid', 'paid_pending_confirmation') THEN
    RAISE EXCEPTION 'pay_pool_charge: obligation status=% is not payable', v_obligation.status
      USING errcode = '22023';
  END IF;

  -- Idempotency pre-check via ledger metadata.
  IF p_client_id IS NOT NULL THEN
    SELECT * INTO v_existing
      FROM public.ledger_entries
     WHERE group_id = v_obligation.group_id
       AND (metadata->>'client_id') = p_client_id::text
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  -- Caller must be an active member of the obligation's group.
  SELECT gm.id INTO v_caller_member
    FROM public.group_members gm
   WHERE gm.group_id = v_obligation.group_id AND gm.user_id = v_uid AND gm.active
   LIMIT 1;
  IF v_caller_member IS NULL THEN
    RAISE EXCEPTION 'pay_pool_charge: caller not an active member of group'
      USING errcode = '42501';
  END IF;

  -- Resolve payer: defaults to the debtor (owed_by), but a third party
  -- can cover the cuota. Payer must be in the group.
  v_payer := COALESCE(p_paid_by_member_id, v_obligation.owed_by_member_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.group_members gm
     WHERE gm.id = v_payer AND gm.group_id = v_obligation.group_id
  ) THEN
    RAISE EXCEPTION 'pay_pool_charge: payer not in group' USING errcode = '22023';
  END IF;

  -- Compute outstanding amount net of any prior partial settlements
  -- (in case the obligation went through partial_paid status — rare
  -- for pool charges today, but the math is correct either way).
  SELECT COALESCE(SUM(so.amount_applied_cents), 0)::bigint
    INTO v_applied
    FROM public.settlement_obligations so
   WHERE so.obligation_id = v_obligation.id;
  v_outstanding := v_obligation.amount_cents - v_applied;
  IF v_outstanding <= 0 THEN
    RAISE EXCEPTION 'pay_pool_charge: no outstanding amount on obligation'
      USING errcode = '22023';
  END IF;

  v_note := NULLIF(trim(coalesce(p_note, '')), '');

  -- Build the contribution ledger entry. The cash flows from the
  -- payer (tri-role: paid_by) to the pool (to_member_id=NULL). The
  -- obligation's owed_by is preserved in metadata so reports can
  -- attribute the cuota even when a third party paid.
  v_metadata := jsonb_build_object(
    'source_obligation_id', v_obligation.id::text,
    'pool_charge_reason',   (v_obligation.metadata->>'reason'),
    'owed_by_member_id',    v_obligation.owed_by_member_id::text
  );
  IF v_note IS NOT NULL THEN
    v_metadata := v_metadata || jsonb_build_object('note', v_note);
  END IF;
  IF p_client_id IS NOT NULL THEN
    v_metadata := v_metadata || jsonb_build_object('client_id', p_client_id::text);
  END IF;
  -- Tri-role payer (memory: doctrine_ledger_tri_role). If the third
  -- party covered the cuota, paid_by_member_id ≠ owed_by — keep it
  -- distinguishable in the audit row.
  IF p_paid_by_member_id IS NOT NULL
     AND p_paid_by_member_id <> v_obligation.owed_by_member_id THEN
    v_metadata := v_metadata || jsonb_build_object('paid_by_member_id', v_payer::text);
  END IF;

  INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by, source_resource_id
  ) VALUES (
    v_obligation.group_id,
    NULL,
    'contribution',
    v_outstanding,
    v_obligation.currency,
    v_payer,                                  -- cash from the payer
    NULL,                                     -- to the pool
    v_metadata,
    now(), now(), v_uid,
    v_obligation.source_resource_id
  )
  RETURNING * INTO v_ledger;

  -- Close the obligation. updated_at moves via trg_obligations_touch_updated_at.
  UPDATE public.obligations
     SET status = 'settled'
   WHERE id = v_obligation.id;

  RETURN v_ledger;

EXCEPTION WHEN unique_violation THEN
  -- Concurrent retry with same client_id.
  IF p_client_id IS NOT NULL THEN
    SELECT * INTO v_existing
      FROM public.ledger_entries
     WHERE group_id = v_obligation.group_id
       AND (metadata->>'client_id') = p_client_id::text
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;
  RAISE;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.pay_pool_charge(uuid, uuid, text, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.pay_pool_charge(uuid, uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.pay_pool_charge(uuid, uuid, text, uuid) IS
  'Money 2.0 Phase 4.4 (mig 20260526040000): close a pool charge obligation by emitting a contribution ledger entry (cash inflow to pool) and marking the obligation settled. Supports tri-role payer (paid_by ≠ owed_by). Idempotent via p_client_id stamped in ledger metadata.';

-- ===========================================================================
-- 5. RPC: void_pool_charge
-- ===========================================================================
-- Anula una cuota sin tocar el ledger. Auth: admin del grupo o el que
-- originalmente la registró (issuance audit lives en metadata.issued_by).

CREATE OR REPLACE FUNCTION public.void_pool_charge(
  p_obligation_id uuid,
  p_reason        text DEFAULT NULL
)
RETURNS public.obligations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_obligation  public.obligations;
  v_is_admin    boolean;
  v_issuer_uid  text;
  v_reason      text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'void_pool_charge: auth required' USING errcode = '42501';
  END IF;

  SELECT * INTO v_obligation
    FROM public.obligations
   WHERE id = p_obligation_id
   FOR UPDATE;
  IF v_obligation.id IS NULL THEN
    RAISE EXCEPTION 'void_pool_charge: obligation not found' USING errcode = '22023';
  END IF;
  IF v_obligation.kind <> 'pool_charge' THEN
    RAISE EXCEPTION 'void_pool_charge: obligation is not a pool charge' USING errcode = '22023';
  END IF;
  IF v_obligation.status = 'voided' THEN
    -- Idempotent: already voided.
    RETURN v_obligation;
  END IF;
  IF v_obligation.status = 'settled' THEN
    RAISE EXCEPTION 'void_pool_charge: cannot void a settled obligation' USING errcode = '22023';
  END IF;

  v_issuer_uid := v_obligation.metadata->>'issued_by';

  SELECT EXISTS (
    SELECT 1 FROM public.group_members gm
     WHERE gm.group_id = v_obligation.group_id
       AND gm.user_id = v_uid
       AND gm.active
       AND gm.role IN ('admin', 'founder')
  ) INTO v_is_admin;

  IF NOT v_is_admin AND v_issuer_uid IS DISTINCT FROM v_uid::text THEN
    RAISE EXCEPTION 'void_pool_charge: only admins or the original issuer may void'
      USING errcode = '42501';
  END IF;

  v_reason := NULLIF(trim(coalesce(p_reason, '')), '');

  UPDATE public.obligations
     SET status = 'voided',
         metadata = metadata || jsonb_build_object(
           'voided_by', v_uid::text,
           'voided_reason', v_reason
         )
   WHERE id = v_obligation.id
   RETURNING * INTO v_obligation;

  RETURN v_obligation;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.void_pool_charge(uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.void_pool_charge(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.void_pool_charge(uuid, text) IS
  'Money 2.0 Phase 4.4 (mig 20260526040000): void an unpaid pool charge. Auth: group admins or the original issuer. Idempotent on already-voided rows. Cannot void settled obligations (use a reverse flow if needed).';

-- ===========================================================================
-- 6. View: extend member_obligations_view to include pool charges in
--    obligation_cents.
-- ===========================================================================
-- Now `obligation_cents` represents EVERYTHING a member owes the pool:
-- fines outstanding + pool charges outstanding (kind='pool_charge' and
-- status active, net of any future bridge allocations). This matches
-- the founder UX: "Debes $X al pool" should aggregate both punitive
-- (fines) and expected (cuotas) debt into a single "what I owe" line.
--
-- net_peer_position_cents is recomputed from the new obligation_cents,
-- so the greedy settlement plan and "Tu posición" automatically
-- pick up pool charges as actionable debt.

CREATE OR REPLACE VIEW public.member_obligations_view AS
WITH stake_cash AS (
  SELECT group_id,
         from_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'contribution'
     AND COALESCE((metadata->>'in_kind'), 'false') <> 'true'
     AND from_member_id IS NOT NULL
   GROUP BY group_id, from_member_id, currency
),
stake_in_kind AS (
  SELECT group_id,
         from_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'contribution'
     AND (metadata->>'in_kind') = 'true'
     AND from_member_id IS NOT NULL
   GROUP BY group_id, from_member_id, currency
),
peer_receivable AS (
  SELECT o.group_id,
         o.owed_to_member_id AS member_id,
         o.currency,
         sum(o.amount_cents - COALESCE(applied.applied_cents, 0))::bigint AS cents
    FROM public.obligations o
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(so.amount_applied_cents), 0)::bigint AS applied_cents
        FROM public.settlement_obligations so
       WHERE so.obligation_id = o.id
    ) applied ON true
   WHERE o.status IN ('open', 'partially_paid', 'paid_pending_confirmation')
     AND o.owed_to_member_id IS NOT NULL
   GROUP BY o.group_id, o.owed_to_member_id, o.currency
),
peer_obligation AS (
  SELECT o.group_id,
         o.owed_by_member_id AS member_id,
         o.currency,
         sum(o.amount_cents - COALESCE(applied.applied_cents, 0))::bigint AS cents
    FROM public.obligations o
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(so.amount_applied_cents), 0)::bigint AS applied_cents
        FROM public.settlement_obligations so
       WHERE so.obligation_id = o.id
    ) applied ON true
   WHERE o.status IN ('open', 'partially_paid', 'paid_pending_confirmation')
     AND o.owed_to_member_id IS NOT NULL          -- exclude pool obligations
   GROUP BY o.group_id, o.owed_by_member_id, o.currency
),
pool_receivable AS (
  SELECT group_id,
         to_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'expense'
     AND to_member_id IS NOT NULL
     AND (
       NOT (metadata ? 'split_breakdown')
       OR jsonb_typeof(metadata->'split_breakdown') <> 'array'
       OR jsonb_array_length(metadata->'split_breakdown') = 0
     )
   GROUP BY group_id, to_member_id, currency
),
reimbursed AS (
  SELECT group_id,
         COALESCE(from_member_id, to_member_id) AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE (type = 'reimbursement'
            AND (from_member_id IS NOT NULL OR to_member_id IS NOT NULL))
      OR (type = 'payout' AND to_member_id IS NOT NULL)
   GROUP BY group_id, COALESCE(from_member_id, to_member_id), currency
),
-- NEW (Phase 4.4): pool charges outstanding per debtor. Materialized
-- directly from `obligations` so the source of truth is the table, not
-- a ledger derivation.
pool_charge_obligation AS (
  SELECT o.group_id,
         o.owed_by_member_id AS member_id,
         o.currency,
         sum(o.amount_cents - COALESCE(applied.applied_cents, 0))::bigint AS cents
    FROM public.obligations o
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(so.amount_applied_cents), 0)::bigint AS applied_cents
        FROM public.settlement_obligations so
       WHERE so.obligation_id = o.id
    ) applied ON true
   WHERE o.status IN ('open', 'partially_paid', 'paid_pending_confirmation')
     AND o.owed_to_member_id IS NULL
     AND o.kind = 'pool_charge'
   GROUP BY o.group_id, o.owed_by_member_id, o.currency
),
fines_issued AS (
  SELECT group_id,
         from_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'fine_issued'
     AND from_member_id IS NOT NULL
   GROUP BY group_id, from_member_id, currency
),
fines_paid AS (
  SELECT group_id,
         from_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'fine_paid'
     AND from_member_id IS NOT NULL
   GROUP BY group_id, from_member_id, currency
),
fines_voided AS (
  SELECT group_id,
         from_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'fine_voided'
     AND from_member_id IS NOT NULL
   GROUP BY group_id, from_member_id, currency
),
settlements_received AS (
  SELECT group_id,
         to_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'settlement'
     AND to_member_id IS NOT NULL
   GROUP BY group_id, to_member_id, currency
),
settlements_sent AS (
  SELECT group_id,
         from_member_id AS member_id,
         currency,
         sum(amount_cents) AS cents
    FROM public.ledger_entries
   WHERE type = 'settlement'
     AND from_member_id IS NOT NULL
   GROUP BY group_id, from_member_id, currency
),
all_keys AS (
  SELECT group_id, member_id, currency FROM stake_cash
  UNION
  SELECT group_id, member_id, currency FROM stake_in_kind
  UNION
  SELECT group_id, member_id, currency FROM peer_receivable
  UNION
  SELECT group_id, member_id, currency FROM peer_obligation
  UNION
  SELECT group_id, member_id, currency FROM pool_receivable
  UNION
  SELECT group_id, member_id, currency FROM reimbursed
  UNION
  SELECT group_id, member_id, currency FROM pool_charge_obligation
  UNION
  SELECT group_id, member_id, currency FROM fines_issued
  UNION
  SELECT group_id, member_id, currency FROM fines_paid
  UNION
  SELECT group_id, member_id, currency FROM fines_voided
  UNION
  SELECT group_id, member_id, currency FROM settlements_received
  UNION
  SELECT group_id, member_id, currency FROM settlements_sent
)
SELECT
  k.group_id,
  k.member_id,
  k.currency,
  COALESCE(sc.cents, 0)::bigint  AS stake_cents,
  COALESCE(sk.cents, 0)::bigint  AS stake_in_kind_cents,
  (
    COALESCE(pr.cents, 0)
    + GREATEST(COALESCE(plr.cents, 0) - COALESCE(re.cents, 0), 0)
  )::bigint AS receivable_cents,
  -- obligation_cents now aggregates fines + pool_charges outstanding.
  -- Both are "owed to the pool" — the UI shows them as one "Debes al pool"
  -- line by default. Surfaces that need the breakdown can fetch
  -- `obligations` directly and filter by `kind`.
  (
    GREATEST(
      COALESCE(fi.cents, 0) - COALESCE(fp.cents, 0) - COALESCE(fv.cents, 0),
      0
    )
    + COALESCE(pco.cents, 0)
  )::bigint AS obligation_cents,
  COALESCE(sr.cents, 0)::bigint  AS settlement_received_cents,
  COALESCE(ss.cents, 0)::bigint  AS settlement_sent_cents,
  (
    COALESCE(pr.cents, 0)
    + GREATEST(COALESCE(plr.cents, 0) - COALESCE(re.cents, 0), 0)
    - COALESCE(pob.cents, 0)
    - GREATEST(COALESCE(fi.cents, 0) - COALESCE(fp.cents, 0) - COALESCE(fv.cents, 0), 0)
    - COALESCE(pco.cents, 0)
  )::bigint AS net_peer_position_cents
FROM all_keys k
LEFT JOIN stake_cash             sc  ON (sc.group_id,  sc.member_id,  sc.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN stake_in_kind          sk  ON (sk.group_id,  sk.member_id,  sk.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN peer_receivable        pr  ON (pr.group_id,  pr.member_id,  pr.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN peer_obligation        pob ON (pob.group_id, pob.member_id, pob.currency) = (k.group_id, k.member_id, k.currency)
LEFT JOIN pool_receivable        plr ON (plr.group_id, plr.member_id, plr.currency) = (k.group_id, k.member_id, k.currency)
LEFT JOIN reimbursed             re  ON (re.group_id,  re.member_id,  re.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN pool_charge_obligation pco ON (pco.group_id, pco.member_id, pco.currency) = (k.group_id, k.member_id, k.currency)
LEFT JOIN fines_issued           fi  ON (fi.group_id,  fi.member_id,  fi.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN fines_paid             fp  ON (fp.group_id,  fp.member_id,  fp.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN fines_voided           fv  ON (fv.group_id,  fv.member_id,  fv.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN settlements_received   sr  ON (sr.group_id,  sr.member_id,  sr.currency)  = (k.group_id, k.member_id, k.currency)
LEFT JOIN settlements_sent       ss  ON (ss.group_id,  ss.member_id,  ss.currency)  = (k.group_id, k.member_id, k.currency);

COMMENT ON VIEW public.member_obligations_view IS
  'Money 2.0 Phase 4.4 (mig 20260526040000): per (group, member, currency) money breakdown. `obligation_cents` now aggregates fines outstanding + pool_charges outstanding (both "owed to the pool"). `net_peer_position_cents` subtracts both. Settlements ya están baked in via bridge allocation on peer obligations; pool charges close via `pay_pool_charge` which writes a contribution ledger entry + marks the obligation settled.';

GRANT SELECT ON public.member_obligations_view TO authenticated;
