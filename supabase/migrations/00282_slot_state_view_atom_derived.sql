-- 00282_slot_state_view_atom_derived.sql
--
-- Sprint 3.8 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F4: slot.status is mutable truth on resources with no recomputable
--   atom set. Companion of mig 00281 which added slotCreated + slotReleased
--   atoms (closing F22 atom gaps).
--
-- This migration creates `slot_state_view` deriving every slot's lifecycle
-- state from the 6 relevant atom types ordered by system_events.seq DESC:
--   - slotCreated   → status='unassigned'
--   - slotAssigned  → status='assigned', assigned_member_id from atom
--   - bookingCreated (payload.slot_id) → status='booked', booking_id
--   - slotReleased  → status='unassigned'
--   - slotExpired   → status='expired'
--   - slotDeclined  → status='declined'
--
-- Notes:
-- - bookingCreated atoms carry resource_id=booking_id and payload.slot_id;
--   the view resolves the slot binding via payload.
-- - assigned_member_id and booking_id are surfaced only when the current
--   status matches (so a "released" slot returns NULL for both, even if
--   prior atoms exist).
-- - Knobs (asset_id, starts_at, ends_at) remain in resources.metadata as
--   creation-time config. slot_state_view reads them through.
-- - resources.status remains as operational cache (Sprint 3.9 registers it
--   in OperationalCacheDoctrine §5). Cache write happens in
--   assign_slot/book_slot/cancel_booking/expire_booking; recompute via
--   slot_state_view always wins on divergence.

CREATE OR REPLACE VIEW public.slot_state_view
WITH (security_invoker = on) AS
WITH slot_direct AS (
  SELECT
    se.resource_id AS slot_id,
    se.event_type, se.occurred_at, se.member_id, se.payload, se.seq,
    NULL::uuid       AS booking_id
  FROM public.system_events se
  JOIN public.resources r ON r.id = se.resource_id AND r.resource_type = 'slot'
  WHERE se.event_type IN ('slotCreated','slotAssigned','slotDeclined','slotReleased','slotExpired')
),
booking_for_slot AS (
  SELECT
    NULLIF(se.payload->>'slot_id','')::uuid AS slot_id,
    se.event_type, se.occurred_at, se.member_id, se.payload, se.seq,
    se.resource_id                          AS booking_id
  FROM public.system_events se
  WHERE se.event_type = 'bookingCreated' AND se.payload ? 'slot_id'
),
all_events AS (
  SELECT * FROM slot_direct
  UNION ALL
  SELECT * FROM booking_for_slot
),
status_chain AS (
  SELECT DISTINCT ON (slot_id)
    slot_id,
    CASE event_type
      WHEN 'slotCreated'    THEN 'unassigned'
      WHEN 'slotAssigned'   THEN 'assigned'
      WHEN 'bookingCreated' THEN 'booked'
      WHEN 'slotReleased'   THEN 'unassigned'
      WHEN 'slotExpired'    THEN 'expired'
      WHEN 'slotDeclined'   THEN 'declined'
    END AS status
  FROM all_events
  WHERE slot_id IS NOT NULL
  ORDER BY slot_id, seq DESC
),
assignment_chain AS (
  SELECT DISTINCT ON (slot_id)
    slot_id,
    member_id AS assigned_member_id
  FROM all_events
  WHERE event_type = 'slotAssigned' AND slot_id IS NOT NULL
  ORDER BY slot_id, seq DESC
),
booking_chain AS (
  SELECT DISTINCT ON (slot_id)
    slot_id, booking_id
  FROM all_events
  WHERE event_type = 'bookingCreated' AND slot_id IS NOT NULL
  ORDER BY slot_id, seq DESC
)
SELECT
  r.id                                                AS slot_id,
  r.group_id,
  COALESCE(sc.status, 'unassigned')                   AS status,
  CASE WHEN sc.status = 'assigned' THEN ac.assigned_member_id END AS assigned_member_id,
  CASE WHEN sc.status = 'booked'   THEN bc.booking_id         END AS booking_id,
  NULLIF(r.metadata->>'asset_id','')::uuid            AS asset_id,
  NULLIF(r.metadata->>'starts_at','')::timestamptz    AS starts_at,
  NULLIF(r.metadata->>'ends_at','')::timestamptz      AS ends_at,
  r.created_by,
  r.created_at,
  r.updated_at,
  r.archived_at
FROM public.resources r
LEFT JOIN status_chain      sc ON sc.slot_id = r.id
LEFT JOIN assignment_chain  ac ON ac.slot_id = r.id
LEFT JOIN booking_chain     bc ON bc.slot_id = r.id
WHERE r.resource_type = 'slot';

COMMENT ON VIEW public.slot_state_view IS
  'Sprint 3.8 (mig 00282) per ConsistencyAudit F4. Atom-derived slot lifecycle state. Status from latest of (slotCreated/slotAssigned/bookingCreated/slotReleased/slotExpired/slotDeclined). assigned_member_id from latest slotAssigned (only if current status=assigned). booking_id from latest bookingCreated (only if current status=booked). Ordered by system_events.seq DESC. resources.status remains as operational cache per OperationalCacheDoctrine §5; slot_state_view is the canonical source. Registered in Plans/Active/ProjectionDoctrine.md §6.';
