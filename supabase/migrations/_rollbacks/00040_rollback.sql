-- 00040 rollback — Clear backfilled event rows from `resources`.
--
-- WARNING: this DELETE will cascade through any FK that points to
-- `resources.id` with on delete cascade. As of this rollback's writing,
-- only the 00041 `fines.resource_id` (added next) references it; if
-- the 00041 migration is also being rolled back, do that first.
--
-- Use only if the backfill itself caused a problem (e.g. unexpected
-- row counts). The 00039 trigger continues firing, so rolling back
-- this without rolling back 00039 means new events still mirror —
-- only the historical rows go away.

delete from public.resources
where resource_type = 'event';
