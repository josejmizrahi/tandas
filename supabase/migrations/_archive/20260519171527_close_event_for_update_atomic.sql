-- 00349 — close_event + close_event_no_fines race-safe & idempotent.
--
-- Bug (V1-02, FASE 0 correctness sprint)
-- ======================================
-- close_event and close_event_no_fines (mig 00236) do:
--
--   1. SELECT * FROM public.resources WHERE id = p_event_id;   -- unlocked
--   2. UPDATE public.resources SET status='completed', ...;     -- no guard
--   3. perform public.record_system_event('eventClosed', ...);  -- emits unconditionally
--
-- Two admins clicking "Close" concurrently both pass step 1 with the same
-- snapshot (status not yet 'completed'), both execute step 2 (Postgres
-- serializes the writes, both succeed), and BOTH execute step 3 →
-- system_events ends up with two `eventClosed` atoms for the same event.
-- process-system-events evaluates each atom independently, so the rule
-- engine fires fines twice for every late attendee.
--
-- We don't add a partial unique index on
-- `system_events(resource_id) WHERE event_type='eventClosed'` because the
-- `eventReopened → eventClosed → eventReopened → eventClosed` cycle is a
-- legitimate user flow (V1-06 covers reopen dedup separately). Dedup
-- lives in the RPC.
--
-- Fix — mirrors mig 00146 (pay_fine FOR UPDATE pattern)
-- =====================================================
-- 1. SELECT ... FOR UPDATE on the resources row. Postgres serializes
--    concurrent callers on the same row: caller B blocks at step 1
--    until caller A commits, then re-reads with status='completed'.
-- 2. Idempotent early return when v_resource.status = 'completed'.
--    No exception — matches pay_fine UX (double-tap doesn't error).
-- 3. Defensive `WHERE status<>'completed'` on the UPDATE plus
--    GET DIAGNOSTICS row_count. If somehow the FOR UPDATE was bypassed
--    (e.g., a future caller forgets the lock), the guard still prevents
--    the second `record_system_event` from firing.
--
-- Both close_event and close_event_no_fines get the identical treatment —
-- same bug, same fix. cancel_event has a related race but emits
-- `eventCancelled` via a trigger, not via record_system_event — out of
-- scope for V1-02.
--
-- Idempotent CREATE OR REPLACE; safe to re-apply.
--
-- Rollback
-- ========
-- _rollbacks/20260519171527_rollback.sql restores the pre-V1-02 bodies
-- from mig 00236 (which reintroduces the race — emergency revert only).

create or replace function public.close_event(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_updated  int;
begin
  -- V1-02: FOR UPDATE serializes concurrent close_event callers on this row.
  select * into v_resource
    from public.resources
   where id = p_event_id and resource_type = 'event'
   for update;
  if v_resource.id is null then raise exception 'event not found'; end if;

  if not public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents') then
    raise exception 'manageEvents permission required' using errcode = '42501';
  end if;

  -- Idempotent return: another close_event call already closed this
  -- event. Return the view row without re-emitting the eventClosed atom.
  if v_resource.status = 'completed' then
    select * into v_view_row from public.events_view where id = p_event_id;
    return v_view_row;
  end if;

  update public.resources
     set status     = 'completed',
         metadata   = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id     = p_event_id
     and status <> 'completed';
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    -- Defensive: unreachable given the FOR UPDATE + status check above,
    -- but if a future caller bypasses the lock we still never double-emit.
    select * into v_view_row from public.events_view where id = p_event_id;
    return v_view_row;
  end if;

  perform public.record_system_event(
    v_resource.group_id, 'eventClosed', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'closed_at', now(),
      'status', 'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event(uuid) is
  'v3 (V1-02, mig 00349): race-safe + idempotent. SELECT FOR UPDATE on the resources row, idempotent return if already closed, WHERE status<>completed guard + row_count check before emitting eventClosed. Prevents double-close race that previously fired rule engine fines twice.';

create or replace function public.close_event_no_fines(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
  v_updated  int;
begin
  select * into v_resource
    from public.resources
   where id = p_event_id and resource_type = 'event'
   for update;
  if v_resource.id is null then raise exception 'event not found'; end if;

  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  if v_resource.status = 'completed' then
    select * into v_view_row from public.events_view where id = p_event_id;
    return v_view_row;
  end if;

  update public.resources
     set status     = 'completed',
         metadata   = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id     = p_event_id
     and status <> 'completed';
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    select * into v_view_row from public.events_view where id = p_event_id;
    return v_view_row;
  end if;

  perform public.record_system_event(
    v_resource.group_id, 'eventClosed', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'closed_at', now(),
      'status', 'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event_no_fines(uuid) is
  'v3 (V1-02, mig 00349): race-safe + idempotent. Same treatment as close_event — SELECT FOR UPDATE + idempotent guard + row_count check before emitting eventClosed.';
