-- R.6.C — Enable pg_cron extension (Supabase) for scheduled virtual event detectors.
-- Supabase coloca pg_cron en schema `extensions` por default; el catálogo lo expone como
-- `cron.schedule(...)` regardless.

create extension if not exists pg_cron with schema extensions;
