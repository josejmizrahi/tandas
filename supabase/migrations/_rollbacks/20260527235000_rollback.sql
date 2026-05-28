-- Rollback for 20260527235000_realtime_publication_v2a1.sql.
--
-- Removes the three canonical tables from supabase_realtime and
-- resets REPLICA IDENTITY to DEFAULT (PK-only old-row image).

do $$
begin
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_events'
  ) then
    alter publication supabase_realtime drop table public.group_events;
  end if;
end$$;

do $$
begin
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_disputes'
  ) then
    alter publication supabase_realtime drop table public.group_disputes;
  end if;
end$$;

do $$
begin
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_decisions'
  ) then
    alter publication supabase_realtime drop table public.group_decisions;
  end if;
end$$;

alter table public.group_events    replica identity default;
alter table public.group_disputes  replica identity default;
alter table public.group_decisions replica identity default;
