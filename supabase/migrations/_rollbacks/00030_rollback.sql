-- 00030 rollback — Unregister dispatch-notifications cron.
--
-- Use when reverting 00030. Outbox rows continue to accumulate in
-- dispatch_status='pending' but nothing drains them until the cron is
-- re-registered. No data loss — push delivery just pauses.

select cron.unschedule('dispatch-notifications-every-minute');
