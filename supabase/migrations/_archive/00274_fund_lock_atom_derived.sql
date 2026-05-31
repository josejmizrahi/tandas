-- 00274_fund_lock_atom_derived.sql
--
-- Sprint 1.2 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F3: fund_lock/fund_unlock muta resources.metadata (locked_at/locked_by/
--   locked_reason) directamente; el atom fundLocked/fundUnlocked se emite DESPUES
--   como decoración. fund_balance_view lee locked_at desde metadata. Viola Article 7
--   (atoms = única verdad histórica) y la regla Truth > Projection > Cache.
--
-- Doctrine restored:
-- - Crea fund_lock_view derivada de system_events(fundLocked/fundUnlocked).
-- - fund_lock/fund_unlock emiten SOLO atom; drop UPDATE de resources.metadata.
-- - fund_balance_view consume fund_lock_view (NO metadata) para exponer locked_at,
--   locked_reason, is_locked.
-- - Cleanup: drop keys metadata.locked_at, metadata.locked_by, metadata.locked_reason
--   de cualquier fund row donde existan (0 rows en producción al 2026-05-17, según
--   audit live; cleanup defensivo idempotente).
-- - Compatibilidad iOS preservada: columnas locked_at + locked_reason siguen
--   en fund_balance_view. Nueva columna is_locked es additive.

-- =============================================================================
-- 1) Cleanup de metadata stale (defensivo; 0 rows hoy).
-- =============================================================================
UPDATE public.resources
   SET metadata = ((coalesce(metadata, '{}'::jsonb)
                     - 'locked_at')
                     - 'locked_by')
                     - 'locked_reason'
 WHERE resource_type = 'fund'
   AND (metadata ? 'locked_at'
        OR metadata ? 'locked_by'
        OR metadata ? 'locked_reason');

-- =============================================================================
-- 2) Projection canónica: fund_lock_view.
--    Latest-per-fund de (fundLocked|fundUnlocked) determina is_locked.
--    Si latest = fundLocked → is_locked=true, locked_at = occurred_at,
--      locked_by + locked_reason desde payload.
--    Si latest = fundUnlocked O nunca hubo evento → is_locked=false (todo NULL).
-- =============================================================================
CREATE OR REPLACE VIEW public.fund_lock_view
WITH (security_invoker = on) AS
WITH lock_events AS (
  SELECT
    se.resource_id          AS fund_id,
    se.event_type,
    se.occurred_at,
    se.payload,
    ROW_NUMBER() OVER (
      PARTITION BY se.resource_id
      ORDER BY se.occurred_at DESC, se.id DESC
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
  'Sprint 1.2 (mig 00274) per ConsistencyAudit F3. Lock state derived from latest fundLocked/fundUnlocked atom per fund. fund_balance_view consumes this (not resources.metadata). Registered in Plans/Active/ProjectionDoctrine.md §6.';

-- =============================================================================
-- 3) Rewrite fund_lock — atom-only, derives "already locked" from view.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fund_lock(p_fund_id uuid, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_group_id  uuid;
  v_archived  timestamptz;
  v_is_locked boolean;
  v_reason    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth required' USING errcode = '42501';
  END IF;

  SELECT group_id, archived_at
    INTO v_group_id, v_archived
    FROM public.resources
   WHERE id = p_fund_id
     AND resource_type = 'fund'
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'fund not found' USING errcode = 'check_violation';
  END IF;
  IF v_archived IS NOT NULL THEN
    RAISE EXCEPTION 'fund is archived' USING errcode = 'check_violation';
  END IF;
  IF NOT public.is_group_admin(v_group_id, v_uid) THEN
    RAISE EXCEPTION 'caller is not a group admin' USING errcode = '42501';
  END IF;

  -- Doctrinal: read lock state from the atom-derived view, not metadata.
  SELECT is_locked INTO v_is_locked
    FROM public.fund_lock_view
   WHERE fund_id = p_fund_id;

  IF COALESCE(v_is_locked, false) THEN
    RAISE EXCEPTION 'fund is already locked' USING errcode = 'check_violation';
  END IF;

  v_reason := nullif(trim(coalesce(p_reason, '')), '');

  -- Atom-only. NO UPDATE de resources.metadata.
  PERFORM public.record_system_event(
    v_group_id,
    'fundLocked',
    p_fund_id,
    NULL,
    jsonb_build_object(
      'locked_by',     v_uid,
      'locked_reason', v_reason
    )
  );
END;
$$;

-- =============================================================================
-- 4) Rewrite fund_unlock — atom-only.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fund_unlock(p_fund_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid := auth.uid();
  v_group_id        uuid;
  v_archived        timestamptz;
  v_is_locked       boolean;
  v_locked_at       timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth required' USING errcode = '42501';
  END IF;

  SELECT group_id, archived_at
    INTO v_group_id, v_archived
    FROM public.resources
   WHERE id = p_fund_id
     AND resource_type = 'fund'
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'fund not found' USING errcode = 'check_violation';
  END IF;
  IF v_archived IS NOT NULL THEN
    RAISE EXCEPTION 'fund is archived' USING errcode = 'check_violation';
  END IF;
  IF NOT public.is_group_admin(v_group_id, v_uid) THEN
    RAISE EXCEPTION 'caller is not a group admin' USING errcode = '42501';
  END IF;

  SELECT is_locked, locked_at
    INTO v_is_locked, v_locked_at
    FROM public.fund_lock_view
   WHERE fund_id = p_fund_id;

  IF NOT COALESCE(v_is_locked, false) THEN
    RAISE EXCEPTION 'fund is not locked' USING errcode = 'check_violation';
  END IF;

  -- Atom-only.
  PERFORM public.record_system_event(
    v_group_id,
    'fundUnlocked',
    p_fund_id,
    NULL,
    jsonb_build_object(
      'unlocked_by',         v_uid,
      'previous_locked_at',  v_locked_at
    )
  );
END;
$$;

-- =============================================================================
-- 5) Rewrite fund_balance_view to consume fund_lock_view instead of metadata.
--    Preserves all existing columns (iOS-compatible). Adds is_locked column.
-- =============================================================================
DROP VIEW IF EXISTS public.fund_balance_view;

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
  -- Lock state from atom-derived view, NOT metadata (doctrinal fix F3).
  COALESCE(flv.is_locked, false)                                      AS is_locked,
  flv.locked_at                                                       AS locked_at,
  flv.locked_reason                                                   AS locked_reason,
  f.archived_at,
  f.created_at
FROM funds f
LEFT JOIN flows           fl  ON fl.fund_id  = f.id
LEFT JOIN public.fund_lock_view flv ON flv.fund_id = f.id;

COMMENT ON VIEW public.fund_balance_view IS
  'Per-(fund, currency) reduction over ledger_entries. Lock state derived from fund_lock_view (atom-driven post mig 00274). Per Plans/Active/Fund.md + Plans/Active/ProjectionDoctrine.md §4.';

-- =============================================================================
-- 6) Permissions preserved.
-- =============================================================================
REVOKE EXECUTE ON FUNCTION public.fund_lock(uuid, text)  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fund_lock(uuid, text)  TO authenticated;
REVOKE EXECUTE ON FUNCTION public.fund_unlock(uuid)      FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fund_unlock(uuid)      TO authenticated;

COMMENT ON FUNCTION public.fund_lock(uuid, text) IS
  'Sprint 1.2 (mig 00274) per ConsistencyAudit F3. Emits fundLocked atom only. Lock state derives from fund_lock_view (no resources.metadata mutation). Idempotent guard: rejects if fund already locked per view.';

COMMENT ON FUNCTION public.fund_unlock(uuid) IS
  'Sprint 1.2 (mig 00274) per ConsistencyAudit F3. Emits fundUnlocked atom only. Lock state derives from fund_lock_view (no resources.metadata mutation). Guard: rejects if fund is not currently locked per view.';
