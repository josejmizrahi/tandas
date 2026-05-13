-- Rollback 00131 — unschedule the reminder cron. Edge function source
-- stays in repo (and on prod until separately undeployed).

select cron.unschedule('emit-event-reminder-events-5min');
