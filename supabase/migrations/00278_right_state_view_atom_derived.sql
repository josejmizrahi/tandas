-- 00278_right_state_view_atom_derived.sql
--
-- Sprint 2.4 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F20: right_holders_view is a projection in name only — it reads
--   holder/delegate/status/suspended_until directly from resources.metadata
--   and resources.status. The atoms (rightCreated/Transferred/Delegated/
--   Revoked/Suspended/Restored/Expired/Exercised) are an audit shadow, not
--   the source of truth.
--
-- This migration:
-- - Creates `right_state_view` deriving holder, delegate, status,
--   last_exercised_at, and suspended_until from system_events (atoms),
--   ordered by seq DESC (mig 00275) for deterministic latest-per-right
--   resolution.
-- - Rewrites `right_holders_view` as a thin wrapper over right_state_view,
--   preserving every column the live iOS app and downstream queries depend
--   on. iOS keeps its current reader (LiveRightRepository.swift consumes
--   right_holders_view); the wrapper transparently delivers atom-derived
--   truth instead of metadata reads.
-- - Knobs (name, target_*, scope, priority, exclusive, transferable,
--   delegable, divisible, expires_at, source) remain in resources.metadata
--   for this migration — they're config, not lifecycle state. Task 12
--   (SPRINT 2.6 / R8) wires update_right_metadata to emit
--   `rightMetadataUpdated` atoms with diff payload, at which point a future
--   right_config_view can derive these from atoms too.
--
-- RPCs are NOT touched in this migration. They still UPDATE resources.metadata
-- (legacy double-write). Task 11 (SPRINT 2.5) drops those writes so the
-- atoms become the only writer. Until Task 11 lands, the metadata writes
-- become inert: right_state_view ignores them entirely.
--
-- Production state at apply time (verified): 0 right resources, 0 right
-- atoms — pure greenfield, no backfill needed.

-- =============================================================================
-- 1) right_state_view — atom-derived truth.
-- =============================================================================
CREATE OR REPLACE VIEW public.right_state_view
WITH (security_invoker = on) AS
WITH right_events AS (
  SELECT
    se.resource_id AS right_id,
    se.event_type,
    se.occurred_at,
    se.member_id,
    se.payload,
    se.seq
  FROM public.system_events se
  JOIN public.resources r
    ON r.id = se.resource_id
   AND r.resource_type = 'right'
  WHERE se.event_type IN (
    'rightCreated','rightTransferred','rightDelegated',
    'rightRevoked','rightSuspended','rightRestored','rightExpired',
    'rightExercised'
  )
),
holder_chain AS (
  -- Latest holder = latest of (rightCreated, rightTransferred).
  SELECT DISTINCT ON (right_id)
    right_id,
    CASE event_type
      WHEN 'rightCreated'     THEN (payload->>'holder_member_id')::uuid
      WHEN 'rightTransferred' THEN (payload->>'to_member_id')::uuid
    END                      AS holder_member_id,
    occurred_at              AS holder_since
  FROM right_events
  WHERE event_type IN ('rightCreated','rightTransferred')
  ORDER BY right_id, seq DESC
),
status_chain AS (
  -- Latest status derived from lifecycle atoms. rightCreated and rightRestored
  -- both resolve to 'active' (creation OR coming out of suspended/revoked).
  SELECT DISTINCT ON (right_id)
    right_id,
    CASE event_type
      WHEN 'rightCreated'   THEN 'active'
      WHEN 'rightRevoked'   THEN 'revoked'
      WHEN 'rightSuspended' THEN 'suspended'
      WHEN 'rightRestored'  THEN 'active'
      WHEN 'rightExpired'   THEN 'expired'
    END                      AS status
  FROM right_events
  WHERE event_type IN (
    'rightCreated','rightRevoked','rightSuspended','rightRestored','rightExpired'
  )
  ORDER BY right_id, seq DESC
),
delegate_chain AS (
  -- Latest rightDelegated payload. Delegation is "active" only if its `until`
  -- timestamp is NULL or in the future; otherwise return NULL even if a
  -- rightDelegated atom exists.
  SELECT DISTINCT ON (right_id)
    right_id,
    (payload->>'delegate_member_id')::uuid                      AS delegate_member_id_raw,
    NULLIF(payload->>'until','')::timestamptz                   AS delegate_until
  FROM right_events
  WHERE event_type = 'rightDelegated'
  ORDER BY right_id, seq DESC
),
suspension_chain AS (
  -- Latest rightSuspended payload. The suspended_until exposure is only
  -- meaningful when status='suspended' (composed in final SELECT).
  SELECT DISTINCT ON (right_id)
    right_id,
    NULLIF(payload->>'until','')::timestamptz                   AS suspended_until_raw
  FROM right_events
  WHERE event_type = 'rightSuspended'
  ORDER BY right_id, seq DESC
),
exercise_chain AS (
  SELECT DISTINCT ON (right_id)
    right_id,
    occurred_at                                                 AS last_exercised_at
  FROM right_events
  WHERE event_type = 'rightExercised'
  ORDER BY right_id, seq DESC
)
SELECT
  r.id                                                          AS right_id,
  r.group_id,
  -- ---- atom-derived lifecycle state ----
  hc.holder_member_id,
  hgm.user_id                                                   AS holder_user_id,
  hc.holder_since,
  CASE
    WHEN dc.delegate_until IS NULL THEN dc.delegate_member_id_raw
    WHEN dc.delegate_until > now() THEN dc.delegate_member_id_raw
    ELSE NULL
  END                                                           AS delegate_member_id,
  CASE
    WHEN dc.delegate_until IS NULL THEN dgm.user_id
    WHEN dc.delegate_until > now() THEN dgm.user_id
    ELSE NULL
  END                                                           AS delegate_user_id,
  dc.delegate_until,
  COALESCE(sc.status, 'active')                                 AS status,
  CASE WHEN COALESCE(sc.status,'active') = 'suspended'
       THEN spc.suspended_until_raw END                          AS suspended_until,
  ec.last_exercised_at,
  -- ---- knobs (config) still from metadata until Task 12 wires diff atoms ----
  (r.metadata->>'name')                                         AS name,
  NULLIF(r.metadata->>'target_resource_id','')::uuid            AS target_resource_id,
  NULLIF(r.metadata->>'target_capability','')                   AS target_capability,
  COALESCE(r.metadata->>'scope','resource')                     AS scope,
  COALESCE((r.metadata->>'priority')::integer, 0)               AS priority,
  COALESCE((r.metadata->>'exclusive')::boolean, false)          AS exclusive,
  COALESCE((r.metadata->>'transferable')::boolean, false)       AS transferable,
  COALESCE((r.metadata->>'delegable')::boolean, false)          AS delegable,
  COALESCE((r.metadata->>'divisible')::boolean, false)          AS divisible,
  NULLIF(r.metadata->>'expires_at','')::timestamptz             AS expires_at,
  NULLIF(r.metadata->>'source','')                              AS source,
  r.created_by,
  r.created_at,
  r.updated_at,
  r.archived_at
FROM public.resources r
LEFT JOIN holder_chain    hc  ON hc.right_id  = r.id
LEFT JOIN status_chain    sc  ON sc.right_id  = r.id
LEFT JOIN delegate_chain  dc  ON dc.right_id  = r.id
LEFT JOIN suspension_chain spc ON spc.right_id = r.id
LEFT JOIN exercise_chain  ec  ON ec.right_id  = r.id
LEFT JOIN public.group_members hgm ON hgm.id = hc.holder_member_id
LEFT JOIN public.group_members dgm ON dgm.id = dc.delegate_member_id_raw
WHERE r.resource_type = 'right';

COMMENT ON VIEW public.right_state_view IS
  'Sprint 2.4 (mig 00278) per ConsistencyAudit F20. Canonical right state derived from system_events (rightCreated/Transferred/Delegated/Revoked/Suspended/Restored/Expired/Exercised) ordered by seq DESC. Replaces metadata reads for holder/delegate/status/suspended_until/last_exercised_at. Knobs (scope, priority, transferable, etc.) remain in metadata until Task 12 atomizes update_right_metadata. Registered in Plans/Active/ProjectionDoctrine.md §6.';

-- =============================================================================
-- 2) Rewrite right_holders_view as a thin wrapper over right_state_view.
--    Preserves all 25 columns iOS / LiveRightRepository consumes today.
--    Drop-in compatible.
-- =============================================================================
DROP VIEW IF EXISTS public.right_holders_view;

CREATE VIEW public.right_holders_view
WITH (security_invoker = on) AS
SELECT
  right_id,
  group_id,
  status,
  name,
  holder_member_id,
  holder_user_id,
  delegate_member_id,
  delegate_user_id,
  delegate_until,
  target_resource_id,
  target_capability,
  scope,
  priority,
  exclusive,
  transferable,
  delegable,
  divisible,
  expires_at,
  suspended_until,
  last_exercised_at,
  source,
  created_by,
  created_at,
  updated_at,
  archived_at
FROM public.right_state_view;

COMMENT ON VIEW public.right_holders_view IS
  'Backward-compatible wrapper over right_state_view (mig 00278). Same column shape as pre-mig version; atom-derived truth replaces metadata reads. iOS LiveRightRepository consumes this without modification.';
