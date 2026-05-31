-- 00105 — Auto-increment public.templates.version on config change.
--
-- Audit task M.12. mig 00021 created public.templates with a `version`
-- column defaulted to 1, but nothing bumps it. Every config edit since
-- (00042 governance defaults, 00051 group_type removal, 00062 default
-- rules, 00063 default roles, 00099 default capabilities) left every
-- row at version=1 — clients have no signal to invalidate their cache.
--
-- This migration:
--   1. Adds a trigger that increments `version` when `config`, `name`,
--      `description`, `icon`, or `available` change. `updated_at` and
--      `version` itself are excluded so the existing updated_at trigger
--      doesn't ping-pong us.
--   2. Backfills no rows — existing version=1 stays as the baseline.
--      Clients reading templates.updated_at OR templates.version will
--      both observe future edits.

create or replace function public.templates_bump_version()
returns trigger
language plpgsql
as $$
begin
  if new.config       is distinct from old.config
     or new.name        is distinct from old.name
     or new.description is distinct from old.description
     or new.icon        is distinct from old.icon
     or new.available   is distinct from old.available
  then
    new.version := old.version + 1;
  end if;
  return new;
end $$;

comment on function public.templates_bump_version() is
  'BEFORE UPDATE trigger for public.templates. Increments version when any user-visible field changes (config, name, description, icon, available). Lets clients cache templates by (id, version) and revalidate on bump.';

drop trigger if exists templates_bump_version on public.templates;
create trigger templates_bump_version
  before update on public.templates
  for each row execute function public.templates_bump_version();
