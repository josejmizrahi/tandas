-- 00049 — Consolidate the source of truth for the basic_fines module.
--
-- Audit: Plans/Active/Primitives.md § 3, slice 1.
--
-- Context:
--   Three columns/fields encode "is the basic_fines module enabled" for a group:
--     1. groups.fines_enabled            boolean column     (migration 00011)
--     2. 'basic_fines' = ANY(active_modules)  jsonb membership  (migration 00019)
--     3. groups.governance ->> 'finesEnabled' jsonb derived (00019 line 103)
--
--   Migration 00019 backfilled active_modules to the full V1 set
--   ["basic_fines","rotating_host","rsvp","check_in","appeal_voting"] for ALL
--   groups regardless of fines_enabled. Result: any group with
--   fines_enabled=false from before 00019 now has "basic_fines" in
--   active_modules anyway — silent divergence between (1) and (2).
--
-- This migration:
--   1. One-time backfill: bring (2) into agreement with (1) for all rows.
--      In V1 the user-facing toggle was fines_enabled, so it wins on conflict.
--   2. Adds a BEFORE INSERT OR UPDATE trigger that keeps (1) and (2) in sync.
--      active_modules is the canonical SoT going forward; fines_enabled
--      mirrors `'basic_fines' = ANY(active_modules)` after every write.
--   3. Adds a CHECK constraint as defense-in-depth so any future write that
--      bypasses the trigger fails loudly instead of silently diverging.
--   4. Asserts the invariant holds for all rows post-backfill.
--
-- Out of scope (separate slice):
--   - groups.governance ->> 'finesEnabled' (3rd source of truth) is NOT
--     touched. Belongs with the broader governance jsonb consolidation
--     tracked in Plans/Active/GovernanceRulesJsonb.md.
--   - iOS callsite migration to CapabilityResolver. Tracked as Slice 2 in
--     Primitives.md § 3.
--   - Dropping groups.fines_enabled. Tracked as Slice 4 (post-paridad
--     window of 2 weeks with the trigger live).
--
-- Rollback: 00049_rollback.sql drops the trigger, function and check
-- constraint. The backfill itself is NOT undone — the data was made
-- consistent and reversing would re-introduce the silent divergence
-- 00019 caused. If pre-00049 state is required, restore from snapshot.

-- =========================================================
-- 1. One-time backfill — fix divergent rows
-- =========================================================

-- Where fines_enabled=false but active_modules contains 'basic_fines',
-- remove 'basic_fines' (V1 user-toggled fines_enabled was the SoT).
update public.groups
set active_modules = active_modules - 'basic_fines'
where fines_enabled = false
  and active_modules ? 'basic_fines';

-- Where fines_enabled=true but active_modules omits 'basic_fines',
-- add it. Defensive — should be empty set after 00019 backfill, but
-- covers any post-00019 row inserted with active_modules='[]'.
update public.groups
set active_modules = active_modules || '["basic_fines"]'::jsonb
where fines_enabled = true
  and not (active_modules ? 'basic_fines');

-- =========================================================
-- 2. Sync trigger
-- =========================================================
--
-- Behaviour:
--   - On INSERT, derive fines_enabled from active_modules.
--   - On UPDATE, if active_modules changed, derive fines_enabled.
--   - On UPDATE, if only fines_enabled changed, mirror it into
--     active_modules (legacy update_group_settings RPC path).
--
-- Net effect: every committed row satisfies
--   fines_enabled = (active_modules ? 'basic_fines').

create or replace function public.groups_sync_basic_fines_module()
returns trigger
language plpgsql
as $$
begin
  -- UPDATE path where ONLY fines_enabled was touched: reflect change
  -- into active_modules so callers using the legacy column keep working.
  if TG_OP = 'UPDATE'
     and NEW.fines_enabled is distinct from OLD.fines_enabled
     and NEW.active_modules is not distinct from OLD.active_modules
  then
    if NEW.fines_enabled and not (NEW.active_modules ? 'basic_fines') then
      NEW.active_modules := NEW.active_modules || '["basic_fines"]'::jsonb;
    elsif not NEW.fines_enabled and (NEW.active_modules ? 'basic_fines') then
      NEW.active_modules := NEW.active_modules - 'basic_fines';
    end if;
  end if;

  -- Always derive fines_enabled from active_modules. active_modules is
  -- canonical going forward; this guarantees the invariant whether the
  -- caller touched one column, the other, or both.
  NEW.fines_enabled := (NEW.active_modules ? 'basic_fines');

  return NEW;
end;
$$;

comment on function public.groups_sync_basic_fines_module() is
  'Keeps groups.fines_enabled in sync with the basic_fines module flag in groups.active_modules. See Plans/Active/Primitives.md § 3 (slice 1).';

drop trigger if exists groups_sync_basic_fines_module on public.groups;

create trigger groups_sync_basic_fines_module
  before insert or update of fines_enabled, active_modules
  on public.groups
  for each row
  execute function public.groups_sync_basic_fines_module();

-- =========================================================
-- 3. Check constraint — defense in depth
-- =========================================================
--
-- The trigger normalizes the two columns BEFORE the constraint runs, so
-- this only fires if (a) a future migration or DML bypasses the trigger
-- (e.g. a TRIGGER on TRUNCATE that reinserts), or (b) the trigger has a
-- bug. Either way, fail loudly.

alter table public.groups
  drop constraint if exists groups_basic_fines_consistent;

alter table public.groups
  add constraint groups_basic_fines_consistent
  check (fines_enabled = (active_modules ? 'basic_fines'));

-- =========================================================
-- 4. Invariant assertion — fail the migration if backfill missed any row
-- =========================================================

do $$
declare
  divergent_count integer;
begin
  select count(*) into divergent_count
  from public.groups
  where fines_enabled <> (active_modules ? 'basic_fines');

  if divergent_count > 0 then
    raise exception
      'Migration 00049 backfill incomplete: % row(s) still divergent between fines_enabled and active_modules',
      divergent_count;
  end if;
end $$;
