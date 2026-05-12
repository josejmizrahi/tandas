-- 00036 rollback — remove groups.category, initials, avatar_url.
--
-- Aplicar SOLO si la migration 00036 introdujo regresión visible.
-- Los datos backfilled se pierden.

alter table public.groups
  drop constraint if exists groups_category_check;

alter table public.groups
  drop column if exists avatar_url,
  drop column if exists initials,
  drop column if exists category;
