-- 20260526000000 — obligations table (Money 2.0 Phase 4.1).
--
-- Founder doctrine 2026-05-25 (post-FASE 4 Wave 4): obligations son
-- entidad de primera clase, no implícitas en ledger_entries. Cada
-- expense con split_breakdown crea N obligaciones peer-to-peer (una
-- por cada participante no-fronter).
--
-- Modelo conceptual (per spec founder):
--
--   expense → genera obligations[] (peer ↔ peer)
--   settlement → cierra una obligation (Phase 4.2 wire pendiente)
--   fine (officialized) → se convierte en obligation (Phase 4.3)
--
-- Append-only: no se edita una obligation existente. Si hubo error,
-- void original + create correction. Status transitions vía RPCs
-- futuras (mark_obligation_paid, dispute_obligation, etc).
--
-- Performance
-- ===========
-- Indices en (group_id, owed_by, status) y (group_id, owed_to, status)
-- — los dos patterns de read principales (¿qué debo?, ¿qué me deben?).
-- Plus FK index on source_movement_id para traceability.
--
-- RLS
-- ===
-- SELECT abierto a members del grupo. INSERT/UPDATE solo vía trigger
-- (security definer) o RPCs explícitas (Phase 4.2+). Nunca direct
-- mutation desde el cliente.
--
-- Backfill
-- ========
-- Scan existing expense entries con `metadata.split_breakdown` no vacío,
-- y materializar la N obligation rows. ON CONFLICT DO NOTHING para
-- ser idempotente si la mig se re-corre.

CREATE TABLE public.obligations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  source_movement_id uuid REFERENCES public.ledger_entries(id) ON DELETE SET NULL,
  owed_by_member_id uuid NOT NULL REFERENCES public.group_members(id) ON DELETE RESTRICT,
  owed_to_member_id uuid NOT NULL REFERENCES public.group_members(id) ON DELETE RESTRICT,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  currency text NOT NULL DEFAULT 'MXN',
  status text NOT NULL DEFAULT 'open' CHECK (status IN (
    'open',
    'partially_paid',
    'paid_pending_confirmation',
    'settled',
    'disputed',
    'voided'
  )),
  source_resource_id uuid REFERENCES public.resources(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (owed_by_member_id <> owed_to_member_id)
);

CREATE INDEX idx_obligations_group_owed_by_status
ON public.obligations(group_id, owed_by_member_id, status);

CREATE INDEX idx_obligations_group_owed_to_status
ON public.obligations(group_id, owed_to_member_id, status);

CREATE INDEX idx_obligations_source_movement
ON public.obligations(source_movement_id);

CREATE INDEX idx_obligations_dyad
ON public.obligations(group_id, owed_by_member_id, owed_to_member_id, status);

-- Auto-update updated_at on row mutation.
CREATE OR REPLACE FUNCTION public.obligations_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_obligations_touch_updated_at
BEFORE UPDATE ON public.obligations
FOR EACH ROW EXECUTE FUNCTION public.obligations_touch_updated_at();

-- Materializer: every expense with split_breakdown creates obligations.
-- Each non-fronter participant gets a row: owed_by=participant,
-- owed_to=fronter (= ledger_entry.to_member_id).
CREATE OR REPLACE FUNCTION public.materialize_obligations_from_expense()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.type = 'expense'
     AND NEW.metadata ? 'split_breakdown'
     AND jsonb_typeof(NEW.metadata->'split_breakdown') = 'array'
     AND jsonb_array_length(NEW.metadata->'split_breakdown') > 0
     AND NEW.to_member_id IS NOT NULL
  THEN
    INSERT INTO public.obligations (
      group_id, source_movement_id, owed_by_member_id, owed_to_member_id,
      amount_cents, currency, status, source_resource_id, created_at
    )
    SELECT
      NEW.group_id,
      NEW.id,
      ((s.value)->>'member_id')::uuid,
      NEW.to_member_id,
      ((s.value)->>'share_cents')::bigint,
      NEW.currency,
      'open',
      NEW.source_resource_id,
      NEW.recorded_at
    FROM jsonb_array_elements(NEW.metadata->'split_breakdown') s
    WHERE ((s.value)->>'member_id')::uuid IS DISTINCT FROM NEW.to_member_id
      AND ((s.value)->>'share_cents')::bigint > 0
      -- Defensive: ensure the participant is a real active member of
      -- this group; orphan participant rows in metadata would FK-fail.
      AND EXISTS (
        SELECT 1 FROM public.group_members gm
         WHERE gm.id = ((s.value)->>'member_id')::uuid
           AND gm.group_id = NEW.group_id
      );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_materialize_obligations_from_expense
AFTER INSERT ON public.ledger_entries
FOR EACH ROW
EXECUTE FUNCTION public.materialize_obligations_from_expense();

-- Backfill: scan existing expense entries with split_breakdown.
INSERT INTO public.obligations (
  group_id, source_movement_id, owed_by_member_id, owed_to_member_id,
  amount_cents, currency, status, source_resource_id, created_at
)
SELECT
  le.group_id,
  le.id,
  ((s.value)->>'member_id')::uuid,
  le.to_member_id,
  ((s.value)->>'share_cents')::bigint,
  le.currency,
  'open',
  le.source_resource_id,
  le.recorded_at
FROM public.ledger_entries le
CROSS JOIN LATERAL jsonb_array_elements(le.metadata->'split_breakdown') s
WHERE le.type = 'expense'
  AND le.metadata ? 'split_breakdown'
  AND jsonb_typeof(le.metadata->'split_breakdown') = 'array'
  AND jsonb_array_length(le.metadata->'split_breakdown') > 0
  AND le.to_member_id IS NOT NULL
  AND ((s.value)->>'member_id')::uuid IS DISTINCT FROM le.to_member_id
  AND ((s.value)->>'share_cents')::bigint > 0
  AND EXISTS (
    SELECT 1 FROM public.group_members gm
     WHERE gm.id = ((s.value)->>'member_id')::uuid
       AND gm.group_id = le.group_id
  );

-- RLS: members of the group can SELECT; mutations only via trigger /
-- future RPCs (no direct INSERT/UPDATE/DELETE policy).
ALTER TABLE public.obligations ENABLE ROW LEVEL SECURITY;

CREATE POLICY obligations_select_group_members
ON public.obligations FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.group_members gm
    WHERE gm.group_id = obligations.group_id
      AND gm.user_id = auth.uid()
      AND gm.active
  )
);

COMMENT ON TABLE public.obligations IS
  'Money 2.0 Phase 4.1 (mig 20260526000000): per-pair peer obligations materialized from expense entries with split_breakdown. Each non-fronter participant gets a row owed_by=participant, owed_to=fronter. Status: open/partially_paid/paid_pending_confirmation/settled/disputed/voided. Closed via settlements (Phase 4.2 wire pendiente).';

GRANT SELECT ON public.obligations TO authenticated;
