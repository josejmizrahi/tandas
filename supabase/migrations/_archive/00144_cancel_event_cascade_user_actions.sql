-- 00144 — Beta 1 Consolidation W2-D4: cancel-event cascades resolve
-- dependent user_actions.
--
-- Bug
-- ===
-- `cancel_event` (mig 00098) flips events.status to 'cancelled' and
-- emits an eventClosed system_event, but it leaves user_actions tied
-- to the cancelled event hanging:
--
--   - `hostAssigned`        (mig 00133) — "Te toca ser anfitrión"
--   - `fineProposalReview`  (mig 00016) — "Revisar multas propuestas"
--   - future `rsvpPending`  (W2-D5)
--
-- After two weeks of real use, every cancelled event leaves an
-- inbox-shaped ghost row pointing at a resource that doesn't exist
-- functionally. Audit Track D #2.
--
-- Fix
-- ===
-- AFTER UPDATE trigger on `public.events` fires when status transitions
-- to 'cancelled' (and wasn't already cancelled). Resolves any open
-- user_action where reference_id = event.id and action_type belongs
-- to the curated dependent list. resolved_at = now() marks them done
-- with no side effect on count or attribution.
--
-- Narrow predicate: only fires on the exact "not-cancelled → cancelled"
-- transition. Re-cancelling an already-cancelled event (shouldn't
-- happen, but) is a no-op. Updating any other column on a cancelled
-- event also no-ops.
--
-- Why a trigger and not inline cleanup inside cancel_event: the
-- cancel path may have non-RPC entry points in the future (admin
-- tooling, automated migration scripts, multi-step orchestrators).
-- Putting the cleanup at the row-level guarantees consistency
-- regardless of how the cancellation got there.
--
-- Idempotency: WHERE resolved_at IS NULL — re-running the same
-- transition (impossible under the predicate, but defensive) finds
-- nothing to update. Safe to re-apply migration.

create or replace function public.on_event_cancelled_resolve_actions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Predicate: transition NOT 'cancelled' → 'cancelled'. Ignore
  -- repeated UPDATEs on already-cancelled rows.
  if new.status = 'cancelled'
     and (old.status is null or old.status <> 'cancelled') then
    update public.user_actions
       set resolved_at = now()
     where reference_id = new.id
       and resolved_at  is null
       and action_type in (
         'hostAssigned',
         'fineProposalReview',
         'rsvpPending'           -- W2-D5 future: harmless until that path ships
       );
  end if;
  return new;
end;
$$;

revoke execute on function public.on_event_cancelled_resolve_actions() from public, anon;
grant  execute on function public.on_event_cancelled_resolve_actions() to authenticated, service_role;

drop trigger if exists trg_on_event_cancelled_resolve_actions on public.events;
create trigger trg_on_event_cancelled_resolve_actions
  after update of status on public.events
  for each row
  when (new.status = 'cancelled' and (old.status is null or old.status <> 'cancelled'))
  execute function public.on_event_cancelled_resolve_actions();

comment on function public.on_event_cancelled_resolve_actions() is
  'W2-D4 (mig 00144): when an event transitions to status=cancelled, auto-resolves any open user_action whose reference_id = event.id and action_type is in the dependent-on-event set (hostAssigned, fineProposalReview, future rsvpPending). Prevents orphan inbox rows.';
