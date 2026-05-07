-- 00039 rollback — Drop the events→resources dual-write trigger.
--
-- Removes the trigger but leaves any rows already mirrored into
-- `resources` intact (ops can decide to TRUNCATE or keep them based
-- on the rollback scenario). The 00040 backfill rollback would clear
-- the rows separately.

drop trigger if exists events_sync_to_resources on public.events;
drop function if exists public.sync_event_to_resource();
drop function if exists public.events_resources_parity_check();
