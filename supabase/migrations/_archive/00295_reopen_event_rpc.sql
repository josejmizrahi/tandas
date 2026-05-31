-- 00295_reopen_event_rpc.sql
--
-- Adds reopen_event RPC + eventReopened atom. Closes a UX dead-end:
-- `close_event_no_fines` and `cancel_event` were both one-way — a host
-- who closed an event by mistake had no path to undo it.
--
-- Semantics:
-- - Permission: host (resources.metadata.host_id) OR manageEvents permission
--   (same gate as close_event_no_fines).
-- - Accepts events in status IN ('completed', 'cancelled'). Idempotent on
--   already-scheduled events (returns silently, no atom).
-- - Flips status back to 'scheduled' and strips metadata.closed_at +
--   metadata.cancelled_at + metadata.cancellation_reason.
-- - Emits `eventReopened` atom with previous_status + reopened_by +
--   reopened_at + title.
-- - Does NOT void fines that were issued before close. If the close path
--   was `close_event` (which auto-fines no-shows), the host should
--   void_fine individually post-reopen.
-- - Whitelisted via register_event_type (mig 00293 pattern — no inline
--   array re-replace).

SELECT public.register_event_type(
  'eventReopened',
  'mig_00295',
  'Reverses close_event_no_fines / cancel_event status flip. Permits status=completed|cancelled → scheduled.'
);

CREATE OR REPLACE FUNCTION public.reopen_event(p_event_id uuid)
RETURNS public.events_view
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_resource     public.resources;
  v_view_row     public.events_view;
  v_host_id      uuid;
  v_prev_status  text;
BEGIN
  SELECT * INTO v_resource
    FROM public.resources
   WHERE id = p_event_id AND resource_type = 'event';
  IF v_resource.id IS NULL THEN
    RAISE EXCEPTION 'event not found' USING errcode = '02000';
  END IF;

  v_host_id := NULLIF(v_resource.metadata->>'host_id', '')::uuid;
  IF NOT (v_host_id = auth.uid()
          OR public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) THEN
    RAISE EXCEPTION 'host or manageEvents permission required'
      USING errcode = '42501';
  END IF;

  v_prev_status := v_resource.status;

  -- Idempotent: already open → return current view, no atom.
  IF v_prev_status NOT IN ('completed', 'cancelled') THEN
    SELECT * INTO v_view_row FROM public.events_view WHERE id = p_event_id;
    RETURN v_view_row;
  END IF;

  UPDATE public.resources
     SET status = 'scheduled',
         metadata = ((metadata - 'closed_at') - 'cancelled_at') - 'cancellation_reason',
         updated_at = now()
   WHERE id = p_event_id;

  PERFORM public.record_system_event(
    v_resource.group_id,
    'eventReopened',
    p_event_id,
    NULL,
    jsonb_build_object(
      'title',           v_resource.metadata->>'title',
      'previous_status', v_prev_status,
      'reopened_by',     auth.uid(),
      'reopened_at',     now()
    )
  );

  SELECT * INTO v_view_row FROM public.events_view WHERE id = p_event_id;
  RETURN v_view_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.reopen_event(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.reopen_event(uuid) TO authenticated;

COMMENT ON FUNCTION public.reopen_event(uuid) IS
  'Reverses close_event_no_fines / cancel_event. Flips status from completed|cancelled back to scheduled, strips closure metadata, emits eventReopened atom. Idempotent on already-open events. Permission: host or manageEvents. Does NOT void fines (admin must void_fine individually).';
