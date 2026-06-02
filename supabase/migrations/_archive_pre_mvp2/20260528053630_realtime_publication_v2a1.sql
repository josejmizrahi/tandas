-- 20260527235000 — Realtime publication for V2-A1 stores.

alter table public.group_events    replica identity full;
alter table public.group_disputes  replica identity full;
alter table public.group_decisions replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_events'
  ) then
    alter publication supabase_realtime add table public.group_events;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_disputes'
  ) then
    alter publication supabase_realtime add table public.group_disputes;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_decisions'
  ) then
    alter publication supabase_realtime add table public.group_decisions;
  end if;
end$$;

comment on table public.group_events is
  'Primitive 13 (Memory). Universal append-only audit log. id is a monotonic database cursor for order/pagination/replay, NOT a gapless sequence and NOT a strict commit-time clock. uuid_id is the stable public identifier for cross-entity references. Use occurred_at/created_at for human chronology. Realtime-published (mig 20260527235000) so live timelines update without pull-to-refresh.';
comment on table public.group_disputes is
  'Primitive 14 (Conflict resolution). State machine: open → mediation → resolved | escalated_to_vote. Realtime-published (mig 20260527235000) so new disputes / state transitions surface live.';
comment on table public.group_decisions is
  'Primitive 16 (Decisions) + 22 (Legitimacy) — every decision records what method made it legitimate. Realtime-published (mig 20260527235000) so vote open/close transitions propagate live.';
