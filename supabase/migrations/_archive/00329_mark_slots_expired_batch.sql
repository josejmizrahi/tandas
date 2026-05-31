-- 00329 — `mark_slots_expired_batch(uuid[])` RPC unifies slotExpired atom +
-- resources.status flip into a single transaction.
--
-- Why
-- ===
-- Plans/Active/CleanupAudit_2026-05-18/06_edge_functions.md §4 #1 + §8 #3:
-- the `emit-slot-system-events` cron currently does two separate writes
-- per slot:
--   (1) supabase.rpc("record_system_events_batch", { … })  — atom emit
--   (2) supabase.from("resources").update({ status: "expired" }) — truth flip
-- These live in two distinct transactions. If (1) succeeds and (2) fails,
-- the atom is permanent but the slot's status stays open. Next cron tick
-- the dedup check at the edge fn catches it (skips re-emission), but the
-- doctrinal invariant — "atoms ARE the truth; status is a derived
-- projection" — is violated: the atom and the projection diverge.
--
-- What
-- ====
-- A SECURITY DEFINER RPC that loops the input slot_ids, and for each:
--   - emits a slotExpired atom via the canonical record_system_event() RPC
--     (which keeps the payload-schema validation + atom guard in the path)
--   - UPDATEs resources.status='expired' for the same slot
-- Both in a single plpgsql block — Postgres wraps it in one transaction,
-- so a failure on either write rolls back the pair. No partial state.
--
-- Filter-guards inside the loop (resource_type='slot', status NOT IN
-- expired/cancelled) make the RPC safe even if the edge fn's dedup is a
-- few ms stale: a slot that's already been marked expired by a parallel
-- run is silently skipped, no atom is re-emitted.
--
-- The edge fn keeps its own SELECT-based dedup (system_events lookup) so
-- the cron does not hammer this RPC with no-op rows; that's a perf
-- decision, not a correctness one.
--
-- Service-role only — internal helper for the emit-slot-system-events
-- cron. Returns the count of slots actually transitioned (which may be
-- less than the input array length if any were already expired).
--
-- Rollback
-- ========
-- _rollbacks/00329_rollback.sql

create or replace function public.mark_slots_expired_batch(
  p_slot_ids uuid[]
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slot   record;
  v_count  int := 0;
begin
  if p_slot_ids is null or array_length(p_slot_ids, 1) is null then
    return 0;
  end if;

  for v_slot in
    select id, group_id, metadata
      from public.resources
     where id = any (p_slot_ids)
       and resource_type = 'slot'
       and status not in ('expired', 'cancelled')
       for update
  loop
    perform public.record_system_event(
      v_slot.group_id,
      'slotExpired',
      v_slot.id,
      null,
      jsonb_build_object(
        'assigned_member_id', v_slot.metadata->>'assigned_member_id',
        'booking_id',         v_slot.metadata->>'booking_id',
        'ends_at',            v_slot.metadata->>'ends_at',
        'asset_id',           v_slot.metadata->>'asset_id'
      )
    );

    update public.resources
       set status = 'expired'
     where id = v_slot.id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.mark_slots_expired_batch(uuid[]) from public, anon, authenticated;
grant  execute on function public.mark_slots_expired_batch(uuid[]) to service_role;

comment on function public.mark_slots_expired_batch(uuid[]) is
  'Atomically emits slotExpired atom + flips resources.status=expired for each given slot id, in a single transaction. Internal helper for emit-slot-system-events cron. Returns count of slots transitioned. Service-role only. Mig 00329 closes the atom-vs-projection split documented in CleanupAudit_2026-05-18 §06.4.1.';
