-- 00350 — reopen_event race-safe + idempotent.
--
-- Bug (V1-06, FASE 0 correctness sprint)
-- ======================================
-- reopen_event (mig 00295) does:
--
--   1. SELECT * FROM resources WHERE id = p_event_id;       -- unlocked
--   2. IF status NOT IN (completed, cancelled) RETURN;       -- snapshot check, no lock
--   3. UPDATE resources SET status='scheduled', ...;         -- no WHERE guard
--   4. PERFORM record_system_event('eventReopened', ...);    -- unconditional
--
-- Two admins clicking "Reopen" concurrently both pass step 1 with the
-- same snapshot (status='completed'), both pass the IN-check in step 2,
-- both execute the UPDATE in step 3 (Postgres serializes the writes,
-- both succeed), and BOTH execute step 4 → system_events ends up with
-- two `eventReopened` atoms for the same resource. Today no rule has
-- `eventReopened` as its trigger so the bug doesn't fire fines, but it
-- corrupts the causal-chain projection (reopen cycle count is off by
-- one) and any future rule with that trigger would double-fire.
--
-- Why NOT a partial unique index
-- ==============================
-- `system_events(resource_id) WHERE event_type='eventReopened'` would
-- prevent the duplicate but ALSO break the legitimate close → reopen →
-- close → reopen cycle (the user can re-reopen after re-closing). Same
-- reasoning as V1-02 / mig 00349 for `eventClosed`. Dedup lives in the
-- RPC.
--
-- Fix — mirrors mig 00349 (close_event) / mig 00146 (pay_fine)
-- ============================================================
-- 1. SELECT ... FOR UPDATE on the resources row. Postgres serializes
--    concurrent callers: caller B blocks until caller A commits, then
--    re-reads with status='scheduled'.
-- 2. Idempotent early return when status NOT IN ('completed','cancelled')
--    (covers both "never closed" and "another reopen call won").
-- 3. Defensive WHERE status IN ('completed','cancelled') guard on the
--    UPDATE plus GET DIAGNOSTICS row_count. If some future caller
--    bypasses the lock the guard still prevents the second
--    record_system_event call.
--
-- Behavior unchanged from caller's perspective: same view row returned,
-- same idempotent semantics on already-scheduled events, same emit on
-- the winning caller.
--
-- Idempotent CREATE OR REPLACE; safe to re-apply.
--
-- Rollback
-- ========
-- _rollbacks/20260519173412_rollback.sql restores the pre-V1-06 body
-- from mig 00295 (which reintroduces the race — emergency revert only).

create or replace function public.reopen_event(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
  v_prev_status text;
  v_updated  int;
begin
  -- V1-06: FOR UPDATE serializes concurrent reopen_event callers on this row.
  select * into v_resource
    from public.resources
   where id = p_event_id and resource_type = 'event'
   for update;
  if v_resource.id is null then
    raise exception 'event not found' using errcode = '02000';
  end if;

  v_host_id := nullif(v_resource.metadata->>'host_id', '')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  v_prev_status := v_resource.status;
  -- Idempotent return: another reopen_event call already moved this
  -- event back to 'scheduled' (or the event was never closed in the
  -- first place). Return the view row without re-emitting eventReopened.
  if v_prev_status not in ('completed', 'cancelled') then
    select * into v_view_row from public.events_view where id = p_event_id;
    return v_view_row;
  end if;

  update public.resources
     set status     = 'scheduled',
         metadata   = ((metadata - 'closed_at') - 'cancelled_at') - 'cancellation_reason',
         updated_at = now()
   where id     = p_event_id
     and status in ('completed', 'cancelled');
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    -- Defensive: unreachable given the FOR UPDATE + status check above,
    -- but if a future caller bypasses the lock we still never double-emit.
    select * into v_view_row from public.events_view where id = p_event_id;
    return v_view_row;
  end if;

  perform public.record_system_event(
    v_resource.group_id, 'eventReopened', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'previous_status', v_prev_status,
      'reopened_by', auth.uid(),
      'reopened_at', now()
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.reopen_event(uuid) is
  'v2 (V1-06, mig 00350): race-safe + idempotent. SELECT FOR UPDATE on the resources row, idempotent return when status NOT IN (completed,cancelled), WHERE status IN (completed,cancelled) guard + row_count check before emitting eventReopened. Prevents double-reopen race that would otherwise produce duplicate eventReopened atoms.';
