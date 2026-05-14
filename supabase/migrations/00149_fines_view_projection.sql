-- 00149 — Constitution §14 Step 3b: fines_view as projection over atoms
--
-- Context
-- =======
-- Step 3a (mig 00148) made fine_issued / fine_paid / fine_voided atoms
-- emit on every transition. This migration creates the projection that
-- derives fines.status, paid, paid_at, waived, waived_at, waived_reason
-- from those atoms + open fine_appeal votes + fine_review_periods.
--
-- Readers (Swift Fine struct, edge functions) switch from `from('fines')`
-- to `from('fines_view')`. The underlying fines table keeps its stored
-- columns intact — they will be dropped in Step 3c after the view has
-- been the single read source for one release cycle.
--
-- Derivation precedence (most specific wins)
-- ==========================================
-- 1. fine_voided atom exists      → status='voided', waived=true
-- 2. fine_paid atom exists         → status='paid',   paid=true
-- 3. open fine_appeal vote exists  → status='in_appeal'
-- 4. auto_generated AND review_period (officialized_at not null OR
--    expires_at < now())          → status='officialized'
-- 5. auto_generated AND within grace → status='proposed'
-- 6. else (manual fine)            → status from stored f.status column
--    (manual fines transit proposed→officialized via officialize_fine
--    RPC which we don't refactor in 3b; this fallback is removed in 3c)
--
-- Performance
-- ===========
-- Index on ledger_entries ((metadata->>'fine_id')) filtered to the 3
-- fine atom types makes correlated subqueries O(log n) per fine. The
-- votes uniq_open_vote_per_reference partial index covers the appeal
-- lookup. fine_review_periods.event_id_key covers grace check.
--
-- Companion: Plans/Active/Constitution.md §14 Step 3b.

BEGIN;

-- ---------------------------------------------------------------------------
-- Part 1 — Index for projection performance
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ledger_entries_fine_id_atoms_idx
    ON public.ledger_entries ((metadata->>'fine_id'))
    WHERE type IN ('fine_issued', 'fine_paid', 'fine_voided');

-- ---------------------------------------------------------------------------
-- Part 2 — The projection
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.fines_view;

CREATE VIEW public.fines_view
WITH (security_invoker = true)
AS
SELECT
    f.id,
    f.group_id,
    f.user_id,
    f.rule_id,
    f.event_id,
    f.resource_id,
    f.reason,
    f.amount,
    -- Derived status: atoms > workflows > stored fallback.
    CASE
        WHEN EXISTS (
            SELECT 1 FROM public.ledger_entries le
             WHERE le.type = 'fine_voided'
               AND (le.metadata->>'fine_id')::uuid = f.id
        ) THEN 'voided'
        WHEN EXISTS (
            SELECT 1 FROM public.ledger_entries le
             WHERE le.type = 'fine_paid'
               AND (le.metadata->>'fine_id')::uuid = f.id
        ) THEN 'paid'
        WHEN EXISTS (
            SELECT 1 FROM public.votes v
             WHERE v.vote_type = 'fine_appeal'
               AND v.reference_id = f.id
               AND v.status = 'open'
        ) THEN 'in_appeal'
        WHEN f.auto_generated AND f.event_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.fine_review_periods frp
             WHERE frp.event_id = f.event_id
               AND (frp.officialized_at IS NOT NULL OR frp.expires_at < now())
        ) THEN 'officialized'
        WHEN f.auto_generated THEN 'proposed'
        ELSE f.status
    END AS status,
    -- Derived paid flag + timestamp from fine_paid atom.
    EXISTS (
        SELECT 1 FROM public.ledger_entries le
         WHERE le.type = 'fine_paid'
           AND (le.metadata->>'fine_id')::uuid = f.id
    ) AS paid,
    (
        SELECT le.occurred_at
          FROM public.ledger_entries le
         WHERE le.type = 'fine_paid'
           AND (le.metadata->>'fine_id')::uuid = f.id
         ORDER BY le.occurred_at DESC
         LIMIT 1
    ) AS paid_at,
    f.paid_to_fund,
    -- Derived waived flag + timestamp + reason from fine_voided atom.
    EXISTS (
        SELECT 1 FROM public.ledger_entries le
         WHERE le.type = 'fine_voided'
           AND (le.metadata->>'fine_id')::uuid = f.id
    ) AS waived,
    (
        SELECT le.occurred_at
          FROM public.ledger_entries le
         WHERE le.type = 'fine_voided'
           AND (le.metadata->>'fine_id')::uuid = f.id
         ORDER BY le.occurred_at DESC
         LIMIT 1
    ) AS waived_at,
    (
        SELECT le.metadata->>'reason'
          FROM public.ledger_entries le
         WHERE le.type = 'fine_voided'
           AND (le.metadata->>'fine_id')::uuid = f.id
         ORDER BY le.occurred_at DESC
         LIMIT 1
    ) AS waived_reason,
    f.appeal_vote_id,
    f.auto_generated,
    f.issued_by,
    f.details,
    f.created_at,
    f.updated_at,
    f.rule_snapshot
FROM public.fines f;

COMMENT ON VIEW public.fines_view IS
    'Constitución §14 Step 3b: projection over fines + ledger_entries '
    '(fine_paid/fine_voided atoms) + votes (fine_appeal) + '
    'fine_review_periods. status, paid, paid_at, waived, waived_at, '
    'waived_reason are DERIVED. Stored columns on fines.* remain for '
    'legacy compat until Step 3c. Uses security_invoker=true so RLS '
    'on fines/ledger_entries/votes/fine_review_periods applies normally.';

COMMIT;
