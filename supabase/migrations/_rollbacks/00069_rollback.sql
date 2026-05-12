-- Rollback for 00069: unschedule the slot-expiry cron.
--
-- The function deployment itself is a separate concern (managed via
-- mcp__supabase__deploy_edge_function). Rollback only removes the
-- scheduled invocation — pending system_events already emitted survive
-- and continue to be processed by the engine.

select cron.unschedule('emit-slot-system-events-5min');
