-- 00302 — Batch RPC `record_system_events_batch(jsonb)` for crons.
--
-- Plans/Active/RolesRemediation_2026-05-17.md V8 close. 8 cron/emit
-- edge functions currently do batch INSERT directly into system_events,
-- bypassing the validation + future schema checks in record_system_event.
-- This helper preserves the 1-round-trip perf characteristic (the cron
-- sends ONE JSON array to ONE RPC) while routing every atom through
-- the canonical emit path.
--
-- Transactional: the whole batch lives in a single plpgsql block, so
-- any record_system_event raise (unknown event_type, payload schema
-- violation in strict mode) rolls back the entire batch. Same failure
-- semantics as the pre-existing batch INSERT (CHECK constraint).
--
-- Service-role only — internal helper for emit-* and auto-* crons.
-- Returns the number of events inserted.

create or replace function public.record_system_events_batch(
  p_events jsonb
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event jsonb;
  v_count int := 0;
begin
  if p_events is null or jsonb_typeof(p_events) <> 'array' then
    raise exception 'record_system_events_batch: p_events must be a jsonb array, got %', jsonb_typeof(p_events);
  end if;

  for v_event in select * from jsonb_array_elements(p_events) loop
    if v_event->>'group_id' is null then
      raise exception 'record_system_events_batch: event missing group_id: %', v_event;
    end if;
    if v_event->>'event_type' is null then
      raise exception 'record_system_events_batch: event missing event_type: %', v_event;
    end if;

    perform public.record_system_event(
      (v_event->>'group_id')::uuid,
      v_event->>'event_type',
      nullif(v_event->>'resource_id', '')::uuid,
      nullif(v_event->>'member_id',   '')::uuid,
      coalesce(v_event->'payload', '{}'::jsonb)
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.record_system_events_batch(jsonb) from public, anon, authenticated;
grant  execute on function public.record_system_events_batch(jsonb) to service_role;

comment on function public.record_system_events_batch(jsonb) is
  'Batch helper for cron/emit edge functions. Accepts a jsonb array of {group_id, event_type, resource_id?, member_id?, payload?}, loops record_system_event for each. Transactional — any single failure rolls back the batch. Service-role only. Returns count inserted.';
