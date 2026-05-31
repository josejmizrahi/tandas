-- Mig 00173: Per-user timezone + locale on profiles
--
-- Constitution Layer 0 (Identity). Until now, notification cron stamped
-- `user_tz` from the group's timezone (mig 00143). For a member traveling
-- abroad or living outside MX, the reminder lands at the wrong wall-clock
-- time. Identity should own tz/locale, not the group.
--
-- We add tz/locale with the project defaults ('America/Mexico_City' /
-- 'es-MX') so existing rows have a sensible value without a backfill
-- step. Future signups inherit the same defaults.
--
-- No CHECK constraint on the values: tz strings come from IANA (`select
-- name from pg_timezone_names`) and locales follow BCP-47 — both
-- catalogs are large and Postgres has no built-in validator. iOS picks
-- from the system list, which is the de-facto whitelist.

alter table public.profiles
  add column if not exists timezone text not null default 'America/Mexico_City',
  add column if not exists locale   text not null default 'es-MX';

comment on column public.profiles.timezone is
  'IANA timezone name (e.g., America/Mexico_City). Source-of-truth for user-scoped notifications; overrides group.timezone when the cron knows the recipient.';
comment on column public.profiles.locale is
  'BCP-47 locale tag (e.g., es-MX, en-US). Drives date/number/currency formatting on the client.';
