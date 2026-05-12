-- 00127 — Drop legacy function overloads that block fresh `supabase start`.
--
-- Background
-- ==========
-- Tier 1.0 (move rollbacks out of forward path) unblocked the
-- duplicate-PK error on `schema_migrations` but exposed a second
-- structural issue: several core RPCs have two or more
-- `create or replace function` definitions across migrations with
-- DIFFERENT parameter lists. Postgres treats these as separate
-- overloads (signature = name + param types, ignoring names and
-- defaults). When a client calls with positional/keyword args and
-- relies on defaults to fill the rest, Postgres can't pick which
-- overload to dispatch → `function name is not unique (SQLSTATE 42725)`.
--
-- On prod the overloads coexist quietly because PostgREST resolves
-- by exact-named arg list (every overload only matches when called
-- with its exact arg set), and the iOS clients always pass the
-- canonical newest-signature set. But `supabase start` in CI does a
-- fresh apply of every migration in order, so all overloads land in
-- the same DB and break the first ambiguous call.
--
-- This migration drops the LEGACY overloads, leaving only the newest
-- signature live. Safe because:
--   - Every caller (iOS, edge fns, e2e tests) uses keyword args
--     matching the newest signature.
--   - The newest signature accepts the same args + extras with
--     defaults, so any older valid call still resolves cleanly.
--   - Drops are guarded by `if exists`; re-running is a no-op.
--
-- Audited overloads (from grep of supabase/migrations/*.sql):
--
--   start_vote
--     keep: 00023 / 00116      (11 types, +p_quorum_min_absolute)
--     drop: 00020              (10 types, no p_quorum_min_absolute)
--   close_event
--     keep: 00007              (6 types)
--     drop: 00005              (0 types, no-arg)
--   close_event_no_fines
--     keep: 00098              (2 types)
--     drop: 00012              (0 types, no-arg)
--   issue_manual_fine
--     keep: 00050              (7 types, +resource_id)
--     drop: 00007/00008/00028  (6 types)
--   create_group_with_admin
--     keep: 00079              (7 types, post-BigBang bare)
--     drop: 00003 / 00010 / 00011 / 00042 / 00051 / 00067 (various)
--
-- create_event_v2 already handled inside 00126 (drops the 13-param
-- legacy before creating the new 15-param). Listed here as a doc
-- breadcrumb.

-- start_vote — drop 10-param 00020 overload.
drop function if exists public.start_vote(
  uuid,    -- p_group_id
  text,    -- p_vote_type
  uuid,    -- p_reference_id
  text,    -- p_title
  text,    -- p_description
  jsonb,   -- p_payload
  integer, -- p_duration_hours
  integer, -- p_quorum_percent
  integer, -- p_threshold_percent
  boolean  -- p_is_anonymous
);

-- close_event — drop 0-arg 00005 overload (kept 6-param 00007).
drop function if exists public.close_event();

-- close_event_no_fines — drop 0-arg 00012 overload (kept 2-param 00098).
drop function if exists public.close_event_no_fines();

-- issue_manual_fine — drop 6-param overloads (kept 7-param 00050).
-- The legacy 6-param sig from 00007/00008/00028 is (p_event_id uuid,
-- p_user_id uuid, p_rule_id uuid, p_amount int, p_reason text,
-- p_evidence jsonb). The 00050 7-param sig adds p_resource_id uuid as
-- the first argument.
drop function if exists public.issue_manual_fine(
  uuid,    -- p_event_id
  uuid,    -- p_user_id
  uuid,    -- p_rule_id
  integer, -- p_amount
  text,    -- p_reason
  jsonb    -- p_evidence
);

-- create_group_with_admin — drop every legacy overload. Audit
-- 2026-05-12: 5+ signatures coexist; 00079 7-param is canonical.
-- Use a DO block to drop all overloads that aren't the canonical one,
-- so we don't have to enumerate every historic signature manually.
do $$
declare
  proc record;
  canonical_args text;
begin
  -- Pin canonical signature from 00079: 7 args
  --   p_name text, p_base_template text, p_initials text, p_category text,
  --   p_currency text, p_timezone text, p_color text
  canonical_args := 'text, text, text, text, text, text, text';

  for proc in
    select pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'create_group_with_admin'
       -- Identity arg list strips DEFAULT clauses, so compare cleanly.
       and pg_get_function_identity_arguments(p.oid) <> canonical_args
  loop
    execute 'drop function if exists public.create_group_with_admin(' || proc.args || ') cascade';
    raise notice '00127 dropped legacy overload create_group_with_admin(%)', proc.args;
  end loop;
end $$;

comment on schema public is
  'Tier 1.0 cleanup: 00127 dropped legacy overloads of start_vote, close_event, close_event_no_fines, issue_manual_fine, create_group_with_admin so `supabase start` in CI no longer hits "function name is not unique" errors.';
