-- 20260526010000 — settlements + settlement_obligations bridge (Money 2.0 Phase 4.2).
--
-- Founder doctrine 2026-05-25: settlements son la capa 4 del modelo de
-- 8 capas. Cierran (parcial o total) obligations de la tabla creada en
-- Phase 4.1 (mig 20260526000000). Append-only en filosofía: rows no se
-- borran; cancelaciones / disputes avanzan el state machine.
--
-- Conceptual flow
-- ===============
--   1. iOS: "Liquidar $50 entre Alice → Bob".
--   2. RPC `record_settlement_v2` crea settlement row (status='confirmed'
--      por ahora; future Phase 4.2.1 introducirá creditor confirmation
--      step via 'initiated' → 'confirmed').
--   3. SELECT obligations WHERE group=g, owed_by=Alice, owed_to=Bob,
--      status IN ('open','partially_paid') ORDER BY created_at ASC.
--   4. FIFO allocation: for each obligation, apply min(remaining_amount,
--      outstanding_obligation). Insert bridge row + update obligation
--      status.
--   5. Insert ledger_entries audit row (type='settlement') — sigue
--      siendo la fuente de auditabilidad histórica.
--   6. Idempotente via p_client_id (partial unique sobre
--      settlements.client_id).
--
-- Why a NEW table vs reusing ledger_entries.type='settlement'
-- ===========================================================
-- ledger_entries is append-only context-free. Settlements need:
--   * Bridge to obligations (which obligations did this close?)
--   * State machine (confirmed/rejected/disputed/cancelled) — ledger
--     rows can't transition.
--   * Auditable per-settlement client_id idempotency separate from
--     ledger_entries.metadata->>'client_id'.
-- Per founder spec: el ledger sigue recibiendo una row de auditoría
-- (type='settlement') para que `member_balances_per_group` siga
-- funcionando. La tabla `settlements` es el modelo canónico de
-- intent + allocation; el ledger es el registro temporal.
--
-- Bridge `settlement_obligations`
-- ===============================
-- (settlement_id, obligation_id) → amount_applied_cents.
-- Allows partial settlements: $50 puede cerrar 2 obligaciones de $30
-- + $20, o cerrar parcialmente una de $100.
--
-- RLS
-- ===
-- SELECT: members of the group.
-- INSERT/UPDATE: solo via RPC (record_settlement_v2, future
-- confirm_settlement, reject_settlement, etc).

CREATE TABLE public.settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  from_member_id uuid NOT NULL REFERENCES public.group_members(id) ON DELETE RESTRICT,
  to_member_id uuid NOT NULL REFERENCES public.group_members(id) ON DELETE RESTRICT,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  currency text NOT NULL DEFAULT 'MXN',
  status text NOT NULL DEFAULT 'confirmed' CHECK (status IN (
    'initiated',
    'confirmed',
    'rejected',
    'disputed',
    'cancelled'
  )),
  -- Audit link: the ledger_entries row written for balance projection.
  ledger_entry_id uuid REFERENCES public.ledger_entries(id) ON DELETE SET NULL,
  -- Optional resource scope ("salda lo de esta cena").
  source_resource_id uuid REFERENCES public.resources(id) ON DELETE SET NULL,
  note text,
  client_id uuid,
  recorded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (from_member_id <> to_member_id)
);

-- Partial unique index for idempotency: same group + same client_id ⇒
-- same settlement (retry-safe).
CREATE UNIQUE INDEX settlements_client_id_unique
ON public.settlements(group_id, client_id)
WHERE client_id IS NOT NULL;

CREATE INDEX idx_settlements_group_from_to
ON public.settlements(group_id, from_member_id, to_member_id, created_at DESC);

CREATE INDEX idx_settlements_group_status
ON public.settlements(group_id, status);

CREATE INDEX idx_settlements_ledger_entry
ON public.settlements(ledger_entry_id);

-- Bridge: which obligations did this settlement close (or partially close)?
CREATE TABLE public.settlement_obligations (
  settlement_id uuid NOT NULL REFERENCES public.settlements(id) ON DELETE CASCADE,
  obligation_id uuid NOT NULL REFERENCES public.obligations(id) ON DELETE RESTRICT,
  amount_applied_cents bigint NOT NULL CHECK (amount_applied_cents > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (settlement_id, obligation_id)
);

CREATE INDEX idx_settlement_obligations_obligation
ON public.settlement_obligations(obligation_id);

-- Auto-update updated_at on row mutation.
CREATE OR REPLACE FUNCTION public.settlements_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_settlements_touch_updated_at
BEFORE UPDATE ON public.settlements
FOR EACH ROW EXECUTE FUNCTION public.settlements_touch_updated_at();

-- RLS
ALTER TABLE public.settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settlement_obligations ENABLE ROW LEVEL SECURITY;

CREATE POLICY settlements_select_group_members
ON public.settlements FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.group_members gm
    WHERE gm.group_id = settlements.group_id
      AND gm.user_id = auth.uid()
      AND gm.active
  )
);

CREATE POLICY settlement_obligations_select_group_members
ON public.settlement_obligations FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.settlements s
    JOIN public.group_members gm ON gm.group_id = s.group_id
    WHERE s.id = settlement_obligations.settlement_id
      AND gm.user_id = auth.uid()
      AND gm.active
  )
);

GRANT SELECT ON public.settlements TO authenticated;
GRANT SELECT ON public.settlement_obligations TO authenticated;

COMMENT ON TABLE public.settlements IS
  'Money 2.0 Phase 4.2 (mig 20260526010000): canonical settlement entity. Closes (partial or total) obligations via the settlement_obligations bridge. State machine: initiated/confirmed/rejected/disputed/cancelled. Idempotent via (group_id, client_id) partial unique. Audit ledger entry linked via ledger_entry_id.';

COMMENT ON TABLE public.settlement_obligations IS
  'Money 2.0 Phase 4.2 (mig 20260526010000): bridge — which obligations did this settlement close, and by how much each. FIFO-allocated by record_settlement_v2.';
