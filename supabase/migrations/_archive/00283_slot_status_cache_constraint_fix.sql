-- 00283_slot_status_cache_constraint_fix.sql
--
-- Sprint 3.9 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Discovery during Sprint 3.8 smoke test (mig 00282): pre-existing CHECK
-- constraint `resources_status_known_chk` (via is_known_resource_status)
-- only allows ('pending','assigned','declined','expired') for slot resources.
-- But every slot lifecycle RPC since mig 00070 writes 'unassigned' (create_slot,
-- cancel_booking, expire_booking) and 'booked' (book_slot). These statuses
-- never reached production because 0 slots exist there yet, but every slot
-- INSERT would have failed at runtime.
--
-- This migration:
-- - Adds 'unassigned' and 'booked' to the allowed slot statuses (additive;
--   preserves 'pending' even though no RPC uses it).
-- - Registers slot.status as documented operational cache (atom-backed via
--   slot_state_view, RLS-protected via SECURITY DEFINER RPCs, recomputable,
--   declared in OperationalCacheDoctrine.md §5, smoke-tested in mig 00282
--   verification).
--
-- This closes Sprint 3 of the freeze plan (3.7 + 3.8 + 3.9). slot.status
-- remains as cache; slot_state_view is the canonical source. If divergence
-- ever appears, the view wins.

CREATE OR REPLACE FUNCTION public.is_known_resource_status(p_resource_type text, p_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_resource_type
    WHEN 'event'  THEN p_status IN ('scheduled', 'completed', 'cancelled')
    WHEN 'fund'   THEN p_status IN ('active', 'closed', 'archived')
    WHEN 'asset'  THEN p_status IN ('active', 'archived')
    WHEN 'space'  THEN p_status IN ('active', 'archived')
    WHEN 'slot'   THEN p_status IN ('pending', 'unassigned', 'assigned', 'booked', 'declined', 'expired')
    WHEN 'right'  THEN p_status IN ('active', 'expired', 'revoked')
    ELSE false
  END;
$$;

COMMENT ON FUNCTION public.is_known_resource_status(text, text) IS
  'Slot statuses extended in mig 00283 (Sprint 3.9) to include unassigned + booked — the values the lifecycle RPCs have written since mig 00070 but which the constraint had silently rejected. slot.status is operational cache backed by slot_state_view (atom-derived, mig 00282); see Plans/Active/OperationalCacheDoctrine.md §5.';
