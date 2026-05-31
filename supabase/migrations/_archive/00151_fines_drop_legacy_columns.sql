-- 00151 — Constitution §14 Step 3c phase 2: drop dead fines columns/triggers
--
-- Context
-- =======
-- After mig 00150 (atom-driven side effects) and the deploy of refactored
-- edge functions (process-system-events, send-fine-reminders,
-- finalize-fine-reviews — version-bumped via MCP), nothing in the system
-- reads or writes the following fines columns anymore:
--
--   status, paid, paid_at, paid_to_fund, waived, waived_at,
--   waived_reason, appeal_vote_id
--
-- They are pure dead weight — readers go through fines_view (mig 00149/
-- 00150), writers (pay_fine / void_fine / officialize_fine / start_fine_appeal
-- / finalize_vote / issue_manual_fine) emit ledger atoms instead.
--
-- This migration removes the columns + their triggers/functions/indexes
-- to align the schema with the constitution: fines.* stores only the
-- immutable identity of the obligation (who/when/why/how_much/which_rule);
-- everything else derives from atoms.
--
-- Companion: Plans/Active/Constitution.md §14 Step 3c.

BEGIN;

-- ---------------------------------------------------------------------------
-- Part 1 — Drop obsolete triggers on public.fines
-- ---------------------------------------------------------------------------
-- These triggers managed column-mutation side effects. The new
-- on_fine_atom_inserted trigger on ledger_entries handles the same
-- side effects atom-side.

DROP TRIGGER IF EXISTS fines_after_status_change ON public.fines;
DROP TRIGGER IF EXISTS fines_resolve_fine_pending ON public.fines;
DROP TRIGGER IF EXISTS fines_resolve_proposal_review ON public.fines;

-- ---------------------------------------------------------------------------
-- Part 2 — Drop obsolete trigger functions
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.on_fine_officialized();
DROP FUNCTION IF EXISTS public.resolve_fine_pending_action();
DROP FUNCTION IF EXISTS public.resolve_fine_proposal_review();

-- ---------------------------------------------------------------------------
-- Part 3 — Drop column-dependent indexes
-- ---------------------------------------------------------------------------

DROP INDEX IF EXISTS public.idx_fines_group_status;
DROP INDEX IF EXISTS public.idx_fines_user_status;

-- ---------------------------------------------------------------------------
-- Part 4 — Drop CHECK constraint + validator function
-- ---------------------------------------------------------------------------

ALTER TABLE public.fines DROP CONSTRAINT IF EXISTS fines_status_check;
DROP FUNCTION IF EXISTS public.is_known_fine_status(text);

-- ---------------------------------------------------------------------------
-- Part 5 — Drop the derived columns
-- ---------------------------------------------------------------------------

ALTER TABLE public.fines DROP COLUMN IF EXISTS status;
ALTER TABLE public.fines DROP COLUMN IF EXISTS paid;
ALTER TABLE public.fines DROP COLUMN IF EXISTS paid_at;
ALTER TABLE public.fines DROP COLUMN IF EXISTS paid_to_fund;
ALTER TABLE public.fines DROP COLUMN IF EXISTS waived;
ALTER TABLE public.fines DROP COLUMN IF EXISTS waived_at;
ALTER TABLE public.fines DROP COLUMN IF EXISTS waived_reason;
ALTER TABLE public.fines DROP COLUMN IF EXISTS appeal_vote_id;

COMMENT ON TABLE public.fines IS
    'Identity record for a monetary fine (Constitución §14 Step 3c). '
    'Stores only immutable facts: who (user_id), when (created_at), '
    'why (reason, rule_id), how much (amount), how generated '
    '(auto_generated, issued_by), and what it relates to '
    '(event_id, resource_id, rule_snapshot, details). State derives '
    'from atoms via fines_view (status/paid/waived/timestamps).';

COMMIT;
