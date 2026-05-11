-- 00096_rollback.sql
-- Drops the seeding trigger + helper functions. Does NOT remove the
-- resource_capabilities rows the backfill inserted — those need a
-- separate manual decision (delete only rows that the seeder added
-- vs rows added manually via EnableCapabilitySheet is non-trivial
-- without an `enabled_by` distinction).

drop trigger if exists resources_seed_event_caps_after_insert on public.resources;
drop function if exists public.trg_resources_seed_event_caps();
drop function if exists public.seed_event_default_capabilities(uuid);
