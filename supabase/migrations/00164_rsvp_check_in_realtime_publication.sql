-- 00164 — Realtime publication + REPLICA IDENTITY FULL for the RSVP /
-- check-in atoms. Closes Gap 6 from the 2026-05-14 constitution audit.
--
-- Why
-- ===
-- `RSVPRealtimeService` (iOS) used to subscribe to `event_attendance`,
-- which mig 00159 dropped. The publication never got the replacement
-- atoms — `rsvp_actions` (mig 00153) + `check_in_actions` (mig 00154) —
-- so the service has been silently broken since the events consolidation
-- shipped. Multi-device RSVP sync inside `EventDetailCoordinator` falls
-- back to manual refresh today.
--
-- Pairs with mig 00161 (publication + REPLICA IDENTITY for the four
-- multi-device tables that landed during W3-E3.1). Same rationale: RLS
-- on these atoms keys off non-PK columns (`resource_id` joins through
-- the parent resource), so REPLICA IDENTITY FULL is required for the
-- realtime layer to evaluate RLS on the dispatched WAL row.
--
-- Cost
-- ====
-- WAL overhead from FULL replica identity is negligible at Beta 1
-- scale (≤ 10 active resources × few atom rows each).
--
-- Verification (post-deploy)
-- ==========================
--   select schemaname, tablename from pg_publication_tables
--   where pubname='supabase_realtime'
--     and tablename in ('rsvp_actions','check_in_actions')
--   order by tablename;
--   -- expect: both present
--
--   select relname, relreplident from pg_class
--   where relnamespace='public'::regnamespace
--     and relname in ('rsvp_actions','check_in_actions');
--   -- expect: relreplident = 'f'

alter table public.rsvp_actions     replica identity full;
alter table public.check_in_actions replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='rsvp_actions'
  ) then
    alter publication supabase_realtime add table public.rsvp_actions;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='check_in_actions'
  ) then
    alter publication supabase_realtime add table public.check_in_actions;
  end if;
end$$;

comment on table public.rsvp_actions is
  'RSVP atoms (mig 00153). Append-only, atom-guarded (mig 00103). Realtime-published (mig 00164) so EventDetailCoordinator sees other members'' RSVP changes on the same event without manual refresh.';

comment on table public.check_in_actions is
  'Check-in atoms (mig 00154). Append-only, atom-guarded. Realtime-published (mig 00164) so EventDetailCoordinator sees arrivals on the same event.';
