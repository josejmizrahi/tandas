-- 00036 — Groups: category, initials, avatar_url (DS v3 §4.7).
--
-- Per docs/DesignSystem.md v3 multi-group architecture: cada grupo tiene
-- una `category` (deriva del template) que determina el color ramp del
-- avatar; `initials` (1-3 chars) para avatar fallback cuando no hay imagen;
-- y `avatar_url` opcional.

alter table public.groups
  add column if not exists category   text,
  add column if not exists initials   text,
  add column if not exists avatar_url text;

-- Backfill category desde group_type (existing values: recurring_dinner,
-- tanda_savings, sports_team, band, study_group, poker, family, travel, other).
update public.groups set category = case group_type
  when 'recurring_dinner' then 'socialRecurring'
  when 'tanda_savings'    then 'rotatingSavings'
  when 'sports_team'      then 'amateurTeam'
  when 'band'             then 'amateurTeam'
  when 'study_group'      then 'professionalInformal'
  when 'poker'            then 'socialRecurring'
  when 'family'           then 'patrimonialFamily'
  when 'travel'           then 'groupTravel'
  when 'other'            then 'socialRecurring'
  else 'socialRecurring'
end
where category is null;

-- Backfill initials: first letter of word 1 + first letter of word 2 si existe.
-- Stopword filter se hace en iOS (RuulGroupAvatar.derivedInitials); aquí
-- simplificamos por consistency entre SQL y Swift no-trivial. El usuario
-- puede override `initials` manualmente al crear grupo en V2 (Phase pending).
update public.groups set initials = upper(
  case
    when array_length(string_to_array(trim(name), ' '), 1) >= 2 then
      substring(trim(split_part(name, ' ', 1)) from 1 for 1) ||
      substring(trim(split_part(name, ' ', 2)) from 1 for 1)
    else
      substring(trim(name) from 1 for 2)
  end
)
where initials is null;

-- Defaults para futuros inserts si la app aún no setea category.
alter table public.groups
  alter column category set default 'socialRecurring';

-- NOT NULL después de backfill (si alguna row queda con NULL, falla aquí).
alter table public.groups
  alter column category set not null,
  alter column initials set not null;

-- Constraint check para category válida (los 10 cases de GroupCategory).
alter table public.groups
  drop constraint if exists groups_category_check;

alter table public.groups
  add constraint groups_category_check
  check (category in (
    'socialRecurring', 'sharedResource', 'rotatingSavings',
    'patrimonialFamily', 'amateurTeam', 'groupTravel',
    'religiousCultural', 'professionalInformal',
    'digitalCommunity', 'commitmentPact'
  ));

comment on column public.groups.category   is 'GroupCategory enum (DS v3 §4.7). Determina color ramp del avatar.';
comment on column public.groups.initials   is 'Iniciales del grupo (1-3 chars) para avatar fallback cuando no hay avatar_url.';
comment on column public.groups.avatar_url is 'URL opcional al avatar del grupo. NULL = usar fallback con iniciales + color ramp.';
