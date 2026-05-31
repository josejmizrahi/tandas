-- 00056 — Eliminate the dormant 3rd source of truth for basic_fines.
--
-- Audit: Plans/Active/Primitives.md § 3.
--
-- Context:
--   Migration 00049 (slice 1) consolidated the SoT between
--     1. groups.fines_enabled            (boolean column)
--     2. 'basic_fines' = ANY(active_modules)  (jsonb membership — canonical)
--   It explicitly left a 3rd location untouched, originally documented
--   as `groups.governance ->> 'finesEnabled'`. That description was a
--   typo: the actual key lives in `groups.settings ->> 'finesEnabled'`,
--   set by 00019 line 103 during the platform v2 backfill.
--
--   Audit done in slice 3 confirmed:
--     - No edge function reads `groups.settings ->> 'finesEnabled'`.
--     - No iOS callsite reads `GroupSettings.finesEnabled` (the field
--       decodes but is never accessed).
--     - The key is therefore dormant write-only state. Worse: as soon
--       as slice 4 drops the legacy boolean, anyone who reaches for
--       this key will get a stale value because nothing keeps it in
--       sync with `active_modules`.
--
-- This migration:
--   1. Removes the `finesEnabled` key from `groups.settings` for every
--      row that has it. Idempotent — rows already without it are
--      unaffected. `jsonb_strip_nulls` not needed: `- 'finesEnabled'`
--      drops the key whether the value is null, true, or false.
--   2. Asserts no rows retain the key post-update.
--
-- After this migration the only remaining locations are the two from
-- slice 1, which the trigger keeps in sync. Slice 4 (drop column) can
-- proceed without leaving dormant divergence behind.
--
-- Out of scope:
--   - The rest of `groups.settings` jsonb (rotation/fund/grace/etc.)
--     is also dormant in V1, but those keys are reserved for Phase 2+
--     primitives (Fund especially). They stay until those primitives
--     ship and the wider consolidation tracked in
--     `Plans/Active/GovernanceRulesJsonb.md` runs.
--   - The Swift `GroupSettings.finesEnabled` field. Dropped in the
--     same iOS commit as this migration; no decoder break since the
--     field is optional.
--
-- Rollback: 00056_rollback.sql restores the key from the legacy
-- column. Safe because the slice 1 trigger keeps fines_enabled
-- canonical with active_modules, so the derived value is correct.

update public.groups
   set settings = settings - 'finesEnabled',
       updated_at = now()
 where settings ? 'finesEnabled';

do $$
declare
  remaining integer;
begin
  select count(*) into remaining
  from public.groups
  where settings ? 'finesEnabled';

  if remaining > 0 then
    raise exception
      'Migration 00056 incomplete: % row(s) still carry settings.finesEnabled',
      remaining;
  end if;
end $$;
