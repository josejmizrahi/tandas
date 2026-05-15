-- Mig 00209: `cancel_event` stops emitting legacy `eventClosed` atom
--
-- Plans/Active/EventResource.md §8 lists `eventCancelled` and `eventClosed`
-- as distinct lifecycle atoms. Until now, `cancel_event` (mig 00158) emitted
-- BOTH:
--   - `eventCancelled` (since mig 00203, via the resources.status trigger)
--   - `eventClosed` with payload `{status: cancelled}` (legacy, from cancel_event RPC)
--
-- The dual emission means a cancellation:
--   - Triggers the rule engine's `eventClosed` evaluator → enumerates
--     members for fines (no-show, didn't RSVP, etc.). Per spec §8/§19, fines
--     should NOT fire on cancellations — you can't no-show a cancelled event.
--   - Surfaces twice in the activity feed if both atoms render.
--
-- This migration drops the legacy `eventClosed` emission from `cancel_event`.
-- Going forward, cancellations only produce `eventCancelled` via the trigger.
-- Existing historical `eventClosed{status:cancelled}` rows in system_events
-- remain valid — ActivitySectionView's legacy compat reader keeps rendering
-- them with "El evento se canceló" copy.
--
-- Rule engine: no rule today uses `eventCancelled` as a trigger, so this is
-- additive going forward (no behavior regression). The rule engine's
-- `eventClosed` evaluator no longer fires on cancellation (correct per spec).
-- Rules that need to react to cancellations specifically (e.g., "if cancelled
-- with <24h notice → reservation deposit penalty") can target `eventCancelled`
-- in their trigger.eventType.

create or replace function public.cancel_event(
  p_event_id uuid,
  p_reason   text default null
)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (public.is_group_admin(v_resource.group_id, auth.uid()) or v_host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;

  -- The status UPDATE fires the on_event_status_cancelled trigger (mig 00203
  -- → mig 00199 in spec-numbering) which emits the `eventCancelled` atom.
  -- We deliberately do NOT emit `eventClosed` here anymore — see mig 00209
  -- header for rationale.
  update public.resources
     set status   = 'cancelled',
         metadata = case
           when p_reason is null then metadata
           else jsonb_set(metadata, '{cancellation_reason}', to_jsonb(p_reason::text))
         end,
         updated_at = now()
   where id = p_event_id;

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.cancel_event(uuid, text) is
  'Cancels an event (sets resources.status=cancelled). v2 (mig 00209): no longer emits the legacy eventClosed atom; the on_event_status_cancelled trigger emits eventCancelled instead. Plans/Active/EventResource.md §8.';
