-- 00275_system_events_seq_and_fund_lock_view_tiebreak.sql
--
-- Sprint 1.2.b doctrinal robustness — companion to mig 00274.
--
-- Problem: system_events.occurred_at defaults to now() (transaction-start).
-- Two atoms emitted in the same transaction share occurred_at. The tiebreak
-- on system_events.id (uuid v4) is random — so "latest atom per resource"
-- becomes non-deterministic for same-txn pairs.
--
-- This is not a production-realistic failure for fund lock/unlock (separated by
-- user interaction across transactions), but it WILL bite us as soon as a
-- rule engine consequence sink emits two atoms in one txn (Sprint 4) or as
-- bulk slot operations land (Sprint 3). Fix the foundation now.
--
-- Solution: add a bigserial `seq` column to system_events. seq monotonically
-- increases per INSERT, regardless of transaction boundaries or shared now().
-- Every "latest atom per X" projection from now on orders by seq DESC.
--
-- Safety vs system_events_processed_at_only_guard (mig 00162): the guard
-- compares to_jsonb(old) - 'processed_at' vs to_jsonb(new) - 'processed_at'.
-- seq is set on INSERT and never updated, so OLD.seq = NEW.seq always,
-- and the diff remains empty on legitimate processed_at flips. No guard
-- change required. Verified against atom_no_mutation_guard contract.

-- =============================================================================
-- 1) Add seq column. bigserial = NOT NULL, auto-incrementing, gap-tolerant.
--    ADD COLUMN bigserial assigns nextval() to each existing row automatically
--    (implementation-defined order via ctid; values are unique). New INSERTs
--    receive monotonic values via DEFAULT nextval, which is all projections
--    going forward care about.
--
--    No explicit backfill UPDATE is performed: the system_events_processed_at_
--    only_guard rejects UPDATE on any row where processed_at is already set
--    (set-once gate). Past row ordering is moot because the fund_lock_view
--    (the first consumer) has zero existing fundLocked/fundUnlocked atoms in
--    production at mig apply time.
-- =============================================================================
ALTER TABLE public.system_events
  ADD COLUMN seq bigserial;

COMMENT ON COLUMN public.system_events.seq IS
  'Sprint 1.2.b (mig 00275). Monotonic insert order. Tiebreak for same-occurred_at projections. Set once on INSERT (bigserial); atom_guard treats as immutable like every other non-processed_at column.';

-- =============================================================================
-- 2) Index for (resource_id, seq DESC) — supports "latest atom per resource"
--    pattern used by fund_lock_view (and forthcoming right_state_view,
--    slot_state_view, etc.).
-- =============================================================================
CREATE INDEX IF NOT EXISTS system_events_resource_seq_desc_idx
  ON public.system_events (resource_id, seq DESC);

-- =============================================================================
-- 3) Recreate fund_lock_view tying ORDER to seq DESC instead of (occurred_at,
--    id) DESC. Same shape, deterministic ordering.
--    Must DROP fund_balance_view first because it depends on fund_lock_view.
-- =============================================================================
DROP VIEW IF EXISTS public.fund_balance_view;
DROP VIEW IF EXISTS public.fund_lock_view;

CREATE VIEW public.fund_lock_view
WITH (security_invoker = on) AS
WITH lock_events AS (
  SELECT
    se.resource_id          AS fund_id,
    se.event_type,
    se.occurred_at,
    se.payload,
    ROW_NUMBER() OVER (
      PARTITION BY se.resource_id
      ORDER BY se.seq DESC
    ) AS rn
  FROM public.system_events se
  JOIN public.resources r
    ON r.id = se.resource_id
   AND r.resource_type = 'fund'
  WHERE se.event_type IN ('fundLocked', 'fundUnlocked')
)
SELECT
  r.id   AS fund_id,
  r.group_id,
  CASE WHEN le.event_type = 'fundLocked' THEN true ELSE false END AS is_locked,
  CASE WHEN le.event_type = 'fundLocked' THEN le.occurred_at END  AS locked_at,
  CASE WHEN le.event_type = 'fundLocked'
       THEN (le.payload->>'locked_by')::uuid
  END                                                              AS locked_by,
  CASE WHEN le.event_type = 'fundLocked' THEN le.payload->>'locked_reason' END
                                                                   AS locked_reason
FROM public.resources r
LEFT JOIN lock_events le
  ON le.fund_id = r.id AND le.rn = 1
WHERE r.resource_type = 'fund';

COMMENT ON VIEW public.fund_lock_view IS
  'Sprint 1.2 (mig 00274) per ConsistencyAudit F3. Lock state derived from latest fundLocked/fundUnlocked atom per fund. Ordered by system_events.seq DESC (mig 00275) for deterministic same-txn tiebreak. Registered in Plans/Active/ProjectionDoctrine.md §6.';

CREATE VIEW public.fund_balance_view
WITH (security_invoker = on) AS
WITH funds AS (
  SELECT r.id, r.group_id, r.metadata, r.archived_at, r.created_at
    FROM public.resources r
   WHERE r.resource_type = 'fund'
), flows AS (
  SELECT
    le.resource_id AS fund_id,
    le.currency,
    (sum(CASE WHEN le.from_member_id IS NOT NULL AND le.to_member_id IS NULL
              THEN le.amount_cents ELSE 0::bigint END))::bigint AS in_cents,
    (sum(CASE WHEN le.from_member_id IS NULL AND le.to_member_id IS NOT NULL
              THEN le.amount_cents ELSE 0::bigint END))::bigint AS out_cents,
    count(*) FILTER (WHERE le.type = 'contribution') AS contribution_count,
    count(*) FILTER (WHERE le.type = 'expense')      AS expense_count,
    max(le.occurred_at)                              AS last_activity_at
    FROM public.ledger_entries le
    JOIN funds f ON f.id = le.resource_id
   GROUP BY le.resource_id, le.currency
)
SELECT
  f.id                                                                AS fund_id,
  f.group_id,
  (f.metadata->>'name')                                               AS name,
  (NULLIF(f.metadata->>'target_amount_cents',''))::bigint             AS target_amount_cents,
  COALESCE(fl.currency, f.metadata->>'currency', 'MXN')               AS currency,
  COALESCE(fl.in_cents, 0::bigint)                                    AS in_cents,
  COALESCE(fl.out_cents, 0::bigint)                                   AS out_cents,
  (COALESCE(fl.in_cents, 0::bigint) - COALESCE(fl.out_cents, 0::bigint)) AS balance_cents,
  COALESCE(fl.contribution_count, 0::bigint)                          AS contribution_count,
  COALESCE(fl.expense_count, 0::bigint)                               AS expense_count,
  fl.last_activity_at,
  COALESCE(flv.is_locked, false)                                      AS is_locked,
  flv.locked_at                                                       AS locked_at,
  flv.locked_reason                                                   AS locked_reason,
  f.archived_at,
  f.created_at
FROM funds f
LEFT JOIN flows                fl  ON fl.fund_id  = f.id
LEFT JOIN public.fund_lock_view flv ON flv.fund_id = f.id;

COMMENT ON VIEW public.fund_balance_view IS
  'Per-(fund, currency) reduction over ledger_entries. Lock state derived from fund_lock_view (atom-driven post mig 00274, seq-ordered post mig 00275). Per Plans/Active/Fund.md + Plans/Active/ProjectionDoctrine.md §4.';
