-- Rollback for 00162_system_events_atom_guard.sql

drop trigger if exists system_events_atom_guard on public.system_events;
drop function if exists public.system_events_processed_at_only_guard();
