-- 20260526030000 — fines → obligations (Money 2.0 Phase 4.3).
--
-- Founder doctrine 2026-05-25 (8-layer money architecture, capa 5):
--   "Multas → obligaciones con causa normativa. Officializa → se
--    convierte en obligation."
--
-- Architecture note
-- =================
-- The `fines` table (post mig 00151) is identity-only — status/paid/
-- voided derive from atoms in `ledger_entries`. Therefore Phase 4.3 is
-- driven by atom emission, NOT by direct fines.* mutations:
--
--   fine_officialized atom  → INSERT obligations row (owed_to=NULL)
--   fine_paid atom          → UPDATE obligations.status='settled'
--   fine_voided atom        → UPDATE obligations.status='voided'
--   fine_issued atom        → no obligation yet (still proposed)
--
-- The obligation matches on metadata.fine_id (the atom carries this
-- in metadata, mig 00148).
--
-- Schema delta
-- ============
-- 1. obligations.owed_to_member_id becomes NULLable.
--    NULL means "owed to the group/pool" (canonical fine case).
-- 2. obligations.metadata jsonb added (default '{}') — stores
--    {fine_id, reason, rule_id} for fines; empty for peer obligations
--    from expense splits.
-- 3. CHECK (owed_by <> owed_to) tolerates NULL trivially.
--
-- The peer-obligation pipeline (mig 20260526000000:
-- materialize_obligations_from_expense) is untouched — it always
-- writes a non-NULL owed_to_member_id, so the relaxed constraint is
-- safely opt-in.
--
-- Reads downstream
-- ================
-- `member_obligations_view` (mig 20260526020000) still derives
-- `obligation_cents` (fines outstanding) from fine atoms via
-- fines_issued − fines_paid − fines_voided CTEs. The new obligation
-- rows are observable but NOT yet the authoritative source for that
-- column — a future migration may switch the view to read from
-- obligations directly. Both representations coexist; backfill keeps
-- them consistent at migration time.

ALTER TABLE public.obligations
  ALTER COLUMN owed_to_member_id DROP NOT NULL;

ALTER TABLE public.obligations
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.obligations.owed_to_member_id IS
  'Money 2.0: peer creditor (FK group_members). NULL means owed to the group/pool (canonical fine case). Phase 4.3 (mig 20260526030000).';

COMMENT ON COLUMN public.obligations.metadata IS
  'Phase 4.3 (mig 20260526030000): small payload for source-specific extras (e.g. fine_id, reason). Peer obligations from expense splits keep this empty by default.';

-- ===========================================================================
-- Trigger: handle fine_* atoms on ledger_entries.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.handle_fine_atom_for_obligation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_fine_id uuid;
  v_existing uuid;
  v_owed_by uuid;
  v_fine_resource_id uuid;
  v_fine_reason text;
  v_fine_rule_id uuid;
BEGIN
  -- Only act on fine atoms.
  IF NEW.type NOT IN ('fine_officialized', 'fine_paid', 'fine_voided') THEN
    RETURN NEW;
  END IF;

  v_fine_id := NULLIF(NEW.metadata->>'fine_id', '')::uuid;
  IF v_fine_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.type = 'fine_officialized' THEN
    -- Idempotency: skip if obligation already exists for this fine.
    SELECT id INTO v_existing
      FROM public.obligations
     WHERE (metadata->>'fine_id') = v_fine_id::text
     LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RETURN NEW;
    END IF;

    v_owed_by := NEW.from_member_id;
    IF v_owed_by IS NULL THEN
      -- Defensive: fine atoms should always carry from_member_id = the
      -- fined member's group_members.id (mig 00148 contract). Skip if
      -- malformed.
      RETURN NEW;
    END IF;

    -- Pull the auxiliary fine context for traceability + resource scope.
    SELECT f.resource_id, f.reason, f.rule_id
      INTO v_fine_resource_id, v_fine_reason, v_fine_rule_id
      FROM public.fines f
     WHERE f.id = v_fine_id
     LIMIT 1;

    INSERT INTO public.obligations (
      group_id, source_movement_id, owed_by_member_id, owed_to_member_id,
      amount_cents, currency, status, source_resource_id, metadata, created_at
    ) VALUES (
      NEW.group_id,
      NEW.id,                         -- atom IS the source movement
      v_owed_by,
      NULL,                           -- owed to the group/pool
      NEW.amount_cents,
      NEW.currency,
      'open',
      v_fine_resource_id,
      jsonb_build_object(
        'fine_id', v_fine_id::text,
        'reason',  v_fine_reason,
        'rule_id', v_fine_rule_id
      ),
      NEW.recorded_at
    );

  ELSIF NEW.type = 'fine_paid' THEN
    UPDATE public.obligations
       SET status = 'settled'
     WHERE (metadata->>'fine_id') = v_fine_id::text
       AND status IN ('open', 'partially_paid', 'paid_pending_confirmation', 'disputed');

  ELSIF NEW.type = 'fine_voided' THEN
    UPDATE public.obligations
       SET status = 'voided'
     WHERE (metadata->>'fine_id') = v_fine_id::text
       AND status IS DISTINCT FROM 'voided';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_handle_fine_atom_for_obligation
AFTER INSERT ON public.ledger_entries
FOR EACH ROW
WHEN (NEW.type IN ('fine_officialized', 'fine_paid', 'fine_voided'))
EXECUTE FUNCTION public.handle_fine_atom_for_obligation();

-- ===========================================================================
-- Backfill: materialize obligations for all historical fine atoms.
-- ===========================================================================
-- Step 1: create rows from fine_officialized atoms (one per fine).
INSERT INTO public.obligations (
  group_id, source_movement_id, owed_by_member_id, owed_to_member_id,
  amount_cents, currency, status, source_resource_id, metadata, created_at
)
SELECT DISTINCT ON ((le.metadata->>'fine_id')::uuid)
  le.group_id,
  le.id,
  le.from_member_id,
  NULL,
  le.amount_cents,
  le.currency,
  'open',
  f.resource_id,
  jsonb_build_object(
    'fine_id', (le.metadata->>'fine_id'),
    'reason',  f.reason,
    'rule_id', f.rule_id,
    'backfilled', true
  ),
  le.recorded_at
FROM public.ledger_entries le
LEFT JOIN public.fines f ON f.id = (le.metadata->>'fine_id')::uuid
WHERE le.type = 'fine_officialized'
  AND (le.metadata->>'fine_id') IS NOT NULL
  AND le.from_member_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.obligations o
     WHERE (o.metadata->>'fine_id') = (le.metadata->>'fine_id')
  )
ORDER BY (le.metadata->>'fine_id')::uuid, le.recorded_at ASC;

-- Step 2: apply paid status to obligations whose fine has a fine_paid atom.
UPDATE public.obligations o
   SET status = 'settled'
  FROM public.ledger_entries le
 WHERE le.type = 'fine_paid'
   AND (le.metadata->>'fine_id') = (o.metadata->>'fine_id')
   AND (o.metadata->>'fine_id') IS NOT NULL
   AND o.status IN ('open', 'partially_paid');

-- Step 3: apply voided status to obligations whose fine has a fine_voided atom.
UPDATE public.obligations o
   SET status = 'voided'
  FROM public.ledger_entries le
 WHERE le.type = 'fine_voided'
   AND (le.metadata->>'fine_id') = (o.metadata->>'fine_id')
   AND (o.metadata->>'fine_id') IS NOT NULL
   AND o.status IS DISTINCT FROM 'voided';

COMMENT ON FUNCTION public.handle_fine_atom_for_obligation() IS
  'Money 2.0 Phase 4.3 (mig 20260526030000): atom-driven obligation lifecycle for fines. fine_officialized → INSERT obligation (owed_to=NULL); fine_paid → status=settled; fine_voided → status=voided. Idempotent on metadata.fine_id.';
