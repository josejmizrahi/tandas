-- Rollback for 00165_capabilities_catalog.sql

drop trigger if exists capabilities_set_updated_at on public.capabilities;
drop policy if exists capabilities_read_authenticated on public.capabilities;
drop table if exists public.capabilities;
