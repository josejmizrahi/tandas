-- Rollback for 20260521154500_backfill_shared_pool_for_existing_groups.sql.
-- Deletes ONLY the rows this brick created (metadata.backfilled=true).
-- Legacy fund rows + any shared pools seeded by create_group_with_admin
-- post-mig-00357 (which DON'T have backfilled=true) are untouched.

delete from public.resources
 where resource_type = 'fund'
   and (metadata->>'is_shared_pool') = 'true'
   and (metadata->>'backfilled')     = 'true';
