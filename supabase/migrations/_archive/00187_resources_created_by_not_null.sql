-- Mig 00187: Enforce resources.created_by NOT NULL
--
-- Constitution: every Resource has provenance — someone created it.
-- The original column allowed NULL (mig 00014) presumably because some
-- early SECURITY DEFINER seeds didn't pass an actor. Audit shows 0 rows
-- with NULL today, so we can tighten the contract now.
--
-- ON DELETE behavior on the FK: still default (NO ACTION). Data-rights
-- deletion (mig 00168) anonymizes profile but doesn't drop auth.users
-- rows, so the FK never fails. If we ever hard-delete an auth.users row
-- we'd need to add ON DELETE SET DEFAULT to a sentinel user; out of
-- scope for now.

alter table public.resources
  alter column created_by set not null;

comment on column public.resources.created_by is
  'Actor who created this resource. NOT NULL — every resource has provenance. FK to auth.users; ON DELETE NO ACTION (data-rights deletion anonymizes profile, never drops auth.users).';
