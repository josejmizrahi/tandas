-- 00065 rollback — Remove Phase 2 modules from public.modules.
--
-- Idempotent. Pre-existing groups that had any of these slugs in
-- `active_modules` will keep them (migration cleanup is forward-
-- only); the resolver returns nothing for them post-rollback so
-- those modules go silent — no crash.

delete from public.modules where id in (
  'slot_assignment',
  'rotating_position',
  'slot_swap_request'
);
