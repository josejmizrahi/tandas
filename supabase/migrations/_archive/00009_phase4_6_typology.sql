-- Phase 4.6: group typology
-- Records what kind of group this is so the UI can apply sensible defaults
-- and (later) gate type-specific features (poker pots, sports rosters, etc).
--
-- Types:
--   recurring_dinner : weekly/monthly meal with rotating host (most common)
--   tanda_savings    : rotating savings pool (the original "tanda")
--   sports_team      : weekly game with no host but with positions
--   study_group      : reading club, chevruta, etc
--   band             : music/creative ensemble; no host rotation
--   poker            : game night with pots; host rotates
--   family           : family Sunday lunches, holidays
--   travel           : recurring trip group with shared funds
--   other            : escape hatch

alter table public.groups
  add column if not exists group_type text not null default 'recurring_dinner';

alter table public.groups
  drop constraint if exists groups_group_type_check;
alter table public.groups
  add constraint groups_group_type_check
  check (group_type in (
    'recurring_dinner','tanda_savings','sports_team','study_group',
    'band','poker','family','travel','other'
  ));
