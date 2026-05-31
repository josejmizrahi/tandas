-- =========================================================
-- Tandas — fully customizable rule engine
-- Tables: profiles · groups · group_members · rules · events
--         event_attendance · votes · vote_ballots · fines
--         pots · pot_entries · expenses · expense_shares · payments
-- =========================================================

create extension if not exists "pgcrypto";

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  avatar_url text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  created_by uuid not null references auth.users(id) on delete cascade,
  event_label text not null default 'Tanda',
  currency text not null default 'MXN',
  timezone text not null default 'America/Mexico_City',
  default_day_of_week int check (default_day_of_week between 0 and 6),
  default_start_time time,
  default_location text,
  rotation_enabled boolean not null default true,
  voting_threshold numeric not null default 0.5 check (voting_threshold > 0 and voting_threshold <= 1),
  voting_quorum    numeric not null default 0.5 check (voting_quorum > 0 and voting_quorum <= 1),
  vote_duration_hours int not null default 48,
  committee_required_for_appeals boolean not null default false,
  fund_enabled boolean not null default true,
  fund_balance numeric(14,2) not null default 0,
  fund_target  numeric(14,2),
  fund_target_label text,
  fund_min_participants int,
  fund_admin uuid references auth.users(id) on delete set null,
  block_unpaid_attendance boolean not null default false,
  invite_code text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 8),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger groups_set_updated_at before update on public.groups
for each row execute function public.set_updated_at();

create table public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name_override text,
  role text not null default 'member' check (role in ('admin','member')),
  on_committee boolean not null default false,
  turn_order int,
  active boolean not null default true,
  joined_at timestamptz not null default now(),
  unique (group_id, user_id)
);
create unique index uq_group_turn on public.group_members(group_id, turn_order)
  where turn_order is not null and active;
create index idx_members_user on public.group_members(user_id);

create or replace function public.is_group_member(gid uuid, uid uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.group_members where group_id=gid and user_id=uid and active);
$$;
revoke execute on function public.is_group_member(uuid, uuid) from public, anon;

create or replace function public.is_group_admin(gid uuid, uid uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.group_members where group_id=gid and user_id=uid and role='admin' and active);
$$;
revoke execute on function public.is_group_admin(uuid, uuid) from public, anon;

create or replace function public.is_group_committee(gid uuid, uid uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.group_members where group_id=gid and user_id=uid and on_committee and active);
$$;
revoke execute on function public.is_group_committee(uuid, uuid) from public, anon;

-- Rules: trigger + action stored as jsonb for full flexibility.
-- Built-in trigger types are documented in src/lib/rule-presets.ts and
-- evaluated by public.evaluate_event_rules().
create table public.rules (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  code text,
  title text not null,
  description text,
  trigger jsonb not null,
  action  jsonb not null default '{"type":"fine"}'::jsonb,
  exceptions jsonb not null default '[]'::jsonb,
  enabled boolean not null default true,
  status text not null default 'active' check (status in ('proposed','active','archived')),
  proposed_by uuid references auth.users(id) on delete set null,
  approved_via_vote_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger rules_set_updated_at before update on public.rules
for each row execute function public.set_updated_at();
create index idx_rules_group on public.rules(group_id);
create index idx_rules_status on public.rules(status);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  title text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  location text,
  host_id uuid references auth.users(id) on delete set null,
  cycle_number int,
  rsvp_deadline timestamptz,
  status text not null default 'scheduled' check (status in ('scheduled','in_progress','completed','cancelled')),
  rules_evaluated_at timestamptz,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger events_set_updated_at before update on public.events
for each row execute function public.set_updated_at();
create index idx_events_group on public.events(group_id);
create index idx_events_starts_at on public.events(starts_at);

create table public.event_attendance (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id  uuid not null references auth.users(id) on delete cascade,
  rsvp_status text not null default 'pending' check (rsvp_status in ('pending','going','maybe','declined')),
  rsvp_at timestamptz,
  arrived_at timestamptz,
  cancelled_same_day boolean not null default false,
  cancelled_reason text,
  no_show boolean not null default false,
  notes text,
  marked_by uuid references auth.users(id) on delete set null,
  unique (event_id, user_id)
);
create index idx_attendance_event on public.event_attendance(event_id);

create table public.votes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  subject_type text not null check (subject_type in ('rule_proposal','rule_repeal','fine_appeal','host_swap','general')),
  subject_id uuid,
  title text not null,
  description text,
  payload jsonb,
  created_by uuid not null references auth.users(id) on delete cascade,
  opens_at timestamptz not null default now(),
  closes_at timestamptz not null,
  status text not null default 'open' check (status in ('open','passed','rejected','cancelled')),
  threshold numeric not null default 0.5,
  quorum numeric not null default 0.5,
  committee_only boolean not null default false,
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger votes_set_updated_at before update on public.votes
for each row execute function public.set_updated_at();
create index idx_votes_group on public.votes(group_id);
create index idx_votes_status on public.votes(status);

create table public.vote_ballots (
  id uuid primary key default gen_random_uuid(),
  vote_id uuid not null references public.votes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  choice text not null check (choice in ('yes','no','abstain')),
  cast_at timestamptz not null default now(),
  unique (vote_id, user_id)
);
create index idx_ballots_vote on public.vote_ballots(vote_id);

alter table public.rules
  add constraint rules_approved_via_vote_fkey
  foreign key (approved_via_vote_id) references public.votes(id) on delete set null;

create table public.fines (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  rule_id uuid references public.rules(id) on delete set null,
  event_id uuid references public.events(id) on delete set null,
  reason text not null,
  amount numeric(12,2) not null check (amount >= 0),
  paid boolean not null default false,
  paid_at timestamptz,
  paid_to_fund boolean not null default false,
  waived boolean not null default false,
  waived_at timestamptz,
  waived_reason text,
  appeal_vote_id uuid references public.votes(id) on delete set null,
  auto_generated boolean not null default false,
  issued_by uuid references auth.users(id) on delete set null,
  details jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger fines_set_updated_at before update on public.fines
for each row execute function public.set_updated_at();
create index idx_fines_group on public.fines(group_id);
create index idx_fines_user on public.fines(user_id);

create table public.pots (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  name text not null,
  buy_in numeric(12,2) not null check (buy_in >= 0),
  currency text not null default 'MXN',
  status text not null default 'open' check (status in ('open','closed','cancelled')),
  winner_id uuid references auth.users(id) on delete set null,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger pots_set_updated_at before update on public.pots
for each row execute function public.set_updated_at();
create index idx_pots_event on public.pots(event_id);

create table public.pot_entries (
  id uuid primary key default gen_random_uuid(),
  pot_id uuid not null references public.pots(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount numeric(12,2) not null check (amount >= 0),
  paid_to_winner boolean not null default false,
  paid_at timestamptz,
  unique (pot_id, user_id)
);
create index idx_pot_entries_pot on public.pot_entries(pot_id);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  paid_by uuid not null references auth.users(id) on delete cascade,
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  expense_date date not null default current_date,
  split_type text not null default 'equal' check (split_type in ('equal','exact','percentage')),
  notes text,
  event_id uuid references public.events(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger expenses_set_updated_at before update on public.expenses
for each row execute function public.set_updated_at();
create index idx_expenses_group on public.expenses(group_id);

create table public.expense_shares (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expenses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount numeric(12,2) not null,
  unique (expense_id, user_id)
);
create index idx_shares_expense on public.expense_shares(expense_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  note text,
  paid_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index idx_payments_group on public.payments(group_id);

-- Net balance per member: expenses paid - shares owed + payments sent - payments received
-- - unpaid fines - pot buy-ins (closed pots) + pot winnings (as winner).
create or replace view public.group_balances
with (security_invoker = true)
as
with paid as (
  select group_id, paid_by as user_id, sum(amount) as total
  from public.expenses group by group_id, paid_by
),
owed as (
  select e.group_id, s.user_id, sum(s.amount) as total
  from public.expense_shares s join public.expenses e on e.id = s.expense_id
  group by e.group_id, s.user_id
),
sent as (select group_id, from_user as user_id, sum(amount) as total from public.payments group by 1,2),
received as (select group_id, to_user as user_id, sum(amount) as total from public.payments group by 1,2),
fines_owed as (
  select group_id, user_id, sum(amount) as total
  from public.fines where paid = false and waived = false
  group by 1,2
),
pot_owed as (
  select p.group_id, pe.user_id, sum(pe.amount) as total
  from public.pot_entries pe join public.pots p on p.id = pe.pot_id
  where p.status = 'closed' and p.winner_id is not null
    and pe.user_id <> p.winner_id and pe.paid_to_winner = false
  group by 1,2
),
pot_won as (
  select p.group_id, p.winner_id as user_id, sum(pe.amount) as total
  from public.pots p join public.pot_entries pe on pe.pot_id = p.id
  where p.status = 'closed' and p.winner_id is not null
    and pe.user_id <> p.winner_id and pe.paid_to_winner = false
  group by 1,2
)
select
  m.group_id,
  m.user_id,
    coalesce(p.total,0)
  - coalesce(o.total,0)
  + coalesce(s.total,0)
  - coalesce(r.total,0)
  - coalesce(f.total,0)
  - coalesce(pow.total,0)
  + coalesce(pw.total,0) as balance
from public.group_members m
left join paid       p on p.group_id  = m.group_id and p.user_id  = m.user_id
left join owed       o on o.group_id  = m.group_id and o.user_id  = m.user_id
left join sent       s on s.group_id  = m.group_id and s.user_id  = m.user_id
left join received   r on r.group_id  = m.group_id and r.user_id  = m.user_id
left join fines_owed f on f.group_id  = m.group_id and f.user_id  = m.user_id
left join pot_owed  pow on pow.group_id= m.group_id and pow.user_id= m.user_id
left join pot_won   pw  on pw.group_id = m.group_id and pw.user_id = m.user_id
where m.active;
grant select on public.group_balances to authenticated;
