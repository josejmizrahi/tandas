-- §0. Extensions + helper functions
create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create or replace function public.atom_no_mutation_guard()
returns trigger language plpgsql as $$
declare
  v_whitelist text[];
  v_col text;
begin
  if TG_ARGV[0] is not null then
    v_whitelist := string_to_array(TG_ARGV[0], ',');
  else
    v_whitelist := ARRAY[]::text[];
  end if;
  foreach v_col in array (
    select array_agg(column_name::text)
    from information_schema.columns
    where table_schema = TG_TABLE_SCHEMA and table_name = TG_TABLE_NAME
  )
  loop
    if v_col = any(v_whitelist) then continue; end if;
    if to_jsonb(new) -> v_col is distinct from to_jsonb(old) -> v_col then
      raise exception 'atom_no_mutation_guard: column % is immutable on table %.%',
        v_col, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    end if;
  end loop;
  return new;
end;
$$;

create or replace function public.atom_no_delete_guard()
returns trigger language plpgsql as $$
begin
  raise exception 'append-only table %.%: delete is not allowed',
    TG_TABLE_SCHEMA, TG_TABLE_NAME;
end;
$$;

create or replace function public.assert_same_group(p_a uuid, p_b uuid)
returns void language plpgsql as $$
begin
  if p_a is null or p_b is null then raise exception 'assert_same_group: null group_id'; end if;
  if p_a is distinct from p_b then raise exception 'cross-tenant violation: group_id mismatch (% vs %)', p_a, p_b; end if;
end;
$$;

create or replace function public.assert_resource_type()
returns trigger language plpgsql as $$
declare
  v_expected text := TG_ARGV[0];
  v_actual   text;
begin
  select resource_type into v_actual from public.group_resources where id = NEW.resource_id;
  if v_actual is distinct from v_expected then
    raise exception 'resource % has type %, expected %', NEW.resource_id, v_actual, v_expected;
  end if;
  return NEW;
end;
$$;

-- §1. Identity
create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  username      text unique,
  display_name  text,
  avatar_url    text,
  bio           text,
  phone         text,
  timezone      text not null default 'UTC',
  locale        text not null default 'es',
  deleted_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.profiles is
  'Primitive 1 (Members) — public per-user identity. 1:1 with auth.users.';
create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- §2. Groups + Purposes
create table public.groups (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique,
  name          text not null,
  description   text,
  purpose_summary text,
  visibility    text not null default 'private'
                check (visibility in ('private', 'unlisted', 'public')),
  status        text not null default 'active'
                check (status in ('active','archived','dissolving','dissolved','deleted')),
  category      text,
  settings      jsonb not null default '{}'::jsonb,
  decision_rules jsonb not null default '{}'::jsonb,
  roles_catalog jsonb not null default '{}'::jsonb,
  archived_at   timestamptz,
  dissolved_at  timestamptz,
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.groups is
  'Primitive 1 (Group identity). decision_rules jsonb carries Permission/Authority config (replaces governance).';
create index groups_status_idx on public.groups(status);
create trigger groups_set_updated_at before update on public.groups
  for each row execute function public.set_updated_at();

create table public.group_purposes (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups(id) on delete cascade,
  kind        text not null check (kind in ('declared','operative','emotional')),
  body        text not null,
  visibility  text not null default 'members'
              check (visibility in ('private','members','public')),
  status      text not null default 'active'
              check (status in ('draft','active','archived')),
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.group_purposes is
  'Primitive 3 (Purpose). Multi-kind. Unique active row per (group, kind).';
create unique index group_purposes_one_active_per_kind
  on public.group_purposes(group_id, kind) where status = 'active';
create index group_purposes_group_idx on public.group_purposes(group_id);
create trigger group_purposes_set_updated_at before update on public.group_purposes
  for each row execute function public.set_updated_at();

-- §3. Memberships
create table public.group_memberships (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups(id) on delete cascade,
  user_id           uuid not null references public.profiles(id) on delete cascade,
  status            text not null default 'active'
                    check (status in ('requested','invited','active','suspended','left','banned')),
  membership_type   text not null default 'member'
                    check (membership_type in ('member','provisional','guest','observer','external')),
  title             text,
  invited_by        uuid references public.profiles(id) on delete set null,
  joined_at         timestamptz,
  provisional_until timestamptz,
  confirmed_at      timestamptz,
  suspended_until   timestamptz,
  suspended_reason  text,
  left_at           timestamptz,
  left_reason       text,
  joined_via        text check (joined_via in ('founder_seed','invite_code','admin_add','placeholder_claim','migration')),
  turn_order        integer,
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (group_id, user_id)
);
comment on table public.group_memberships is
  'Primitives 1 (Members), 2 (Membership boundary), 15 (Entry/Exit). status = lifecycle, membership_type = quality of belonging.';
create index group_memberships_group_idx on public.group_memberships(group_id);
create index group_memberships_user_idx on public.group_memberships(user_id);
create index group_memberships_active_idx on public.group_memberships(group_id, user_id) where status = 'active';
create trigger group_memberships_set_updated_at before update on public.group_memberships
  for each row execute function public.set_updated_at();

create table public.group_membership_events (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  membership_id   uuid not null references public.group_memberships(id) on delete cascade,
  actor_user_id   uuid references public.profiles(id) on delete set null,
  event_type      text not null check (event_type in (
                    'requested','invited','joined','provisional_started','confirmed',
                    'suspended','reactivated','left','removed','banned',
                    'role_assigned','role_revoked','type_changed','other'
                  )),
  reason          text,
  payload         jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
comment on table public.group_membership_events is
  'Primitive 15 (Entry/Exit audit). Append-only.';
create index group_membership_events_membership_idx on public.group_membership_events(membership_id);
create trigger group_membership_events_atom_guard before update on public.group_membership_events
  for each row execute function public.atom_no_mutation_guard();
create trigger group_membership_events_no_delete before delete on public.group_membership_events
  for each row execute function public.atom_no_delete_guard();
