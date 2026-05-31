-- Retire the system_events.event_type whitelist.
--
-- Why
-- ===
-- Mig 00293 (2026-05-17) moved the event_type validation from a function
-- literal array to a `known_event_types` table + BEFORE INSERT trigger.
-- The goal was to fix parallel-branch losses (groupRolesChanged kept
-- disappearing when migrations CREATE OR REPLACE'd the check function).
--
-- That goal is achieved by table-backed storage, but the table introduced
-- new fragilities that compound over time:
--
--   1. Every new atom needs a migration to register itself. Friction on a
--      growing codebase; easy to forget; failures show up only at runtime
--      with cryptic "unknown system_event event_type: X" errors.
--   2. The catalog is operational state, not declarative: dashboard
--      inserts (e.g. `member.placeholder_created`, `member.claimed`,
--      `member.merge_declined` — added live, never via mig file) get
--      lost when the data is wiped. We hit this exact failure mode
--      2026-05-26 after the founder's reset-and-retest cycle: groups,
--      members and pendings all broke on event types that "used to work."
--   3. It's frontier validation: every emitter is already a SECURITY
--      DEFINER RPC in `public`, gated behind RLS/has_permission. There
--      is no client-writable path to `system_events`. The whitelist
--      protects against typos in code that ship as PRs — code review
--      and tests are the right defense for that, not a runtime catalog.
--
-- What this migration does
-- ========================
--   1. Drops the BEFORE INSERT/UPDATE trigger on `system_events` so
--      inserts no longer pay a per-row function call.
--   2. Drops the guard function `guard_system_events_event_type_known`.
--   3. Drops the `known_event_types` table (cascade — its RLS policies
--      go with it).
--   4. Converts `register_event_type(text, text, text)` and
--      `is_known_system_event_type(text)` to no-op stubs so historical
--      migrations that called them (mig 00295, 20260519024039, the
--      member.* helper) still apply cleanly when the migration set is
--      replayed against a fresh database. Stubs are immutable.
--
-- What this migration does NOT do
-- ===============================
--   - It does not relax any other system_events constraint: NOT NULL on
--     event_type still applies; `atom_no_mutation_guard` (mig 00103)
--     still rejects UPDATE/DELETE; RLS on `system_events` still gates
--     reads to group members; INSERTs still require SECURITY DEFINER
--     RPC context (no anon/authenticated GRANT).
--   - It does not audit existing emitters. If a buggy RPC ever started
--     writing `event_type='lolwut'`, this migration removes the safety
--     net that would surface it at insert time. Code review + tests are
--     the new line of defense.
--
-- Rollback
-- ========
-- This migration is destructive of the catalog. Reverting requires
-- recreating the table, re-registering every emitted event_type, and
-- re-installing the BEFORE trigger. Snapshot the catalog before applying
-- if you want a precise restore path:
--
--   create table _backup_known_event_types as select * from public.known_event_types;
--
-- (Run that adhoc, outside this mig, only if you want a fallback.)

-- 1. Drop the BEFORE trigger.
drop trigger if exists system_events_event_type_known_trg on public.system_events;

-- 2. Drop the guard function.
drop function if exists public.guard_system_events_event_type_known();

-- 3. Drop the catalog table (cascade brings policies + indexes).
drop table if exists public.known_event_types cascade;

-- 4. Backwards-compat stubs so historical migrations keep applying.

create or replace function public.register_event_type(
  p_event_type       text,
  p_source_migration text,
  p_notes            text default null
) returns void
language sql
immutable
set search_path = public, pg_catalog
as $$
  -- No-op since mig 20260526100000_drop_event_type_whitelist.
  -- Retained so historical migrations that called this function still
  -- apply cleanly against a fresh database.
  select null::void;
$$;

revoke execute on function public.register_event_type(text, text, text) from public, anon, authenticated;

comment on function public.register_event_type(text, text, text) is
  'No-op stub (mig 20260526100000_drop_event_type_whitelist). The known_event_types catalog was retired. Retained as a stub so historical migrations that called this function (mig 00295, 20260519024039, etc.) still apply against a fresh database.';

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = public, pg_catalog
as $$
  -- Always true since mig 20260526100000_drop_event_type_whitelist.
  -- The known_event_types catalog was retired. Retained as a stub for
  -- backwards compatibility with any historical caller.
  select true;
$$;

revoke execute on function public.is_known_system_event_type(text) from public, anon;
grant  execute on function public.is_known_system_event_type(text) to authenticated, service_role;

comment on function public.is_known_system_event_type(text) is
  'No-op stub (mig 20260526100000_drop_event_type_whitelist). Always returns true. The known_event_types catalog was retired; type validation is now the responsibility of the emitter (every emitter is a SECURITY DEFINER RPC in public, code-reviewed at write time). Retained for backwards compatibility.';
