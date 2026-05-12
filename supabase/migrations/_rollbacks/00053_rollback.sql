-- Rollback for 00047 — restore legacy appeals/appeal_votes tables.
--
-- WARNING: this rollback recreates the empty schema only. It does NOT
-- backfill data from votes/vote_casts (the rollforward direction lost
-- nothing because pre-drop tables were already empty per audit). If
-- prod data exists in votes(vote_type='fine_appeal') after rollforward,
-- the rollback will leave it in votes/ untouched.

create table if not exists public.appeals (
  id                    uuid primary key default gen_random_uuid(),
  fine_id               uuid not null references public.fines(id) on delete cascade,
  appellant_member_id   uuid not null references public.group_members(id),
  reason                text not null,
  status                text not null default 'voting',
  voting_started_at     timestamptz not null default now(),
  voting_ends_at        timestamptz not null,
  resolved_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint appeals_status_check
    check (status in ('voting', 'resolved_in_favor', 'resolved_against', 'expired'))
);

create table if not exists public.appeal_votes (
  id          uuid primary key default gen_random_uuid(),
  appeal_id   uuid not null references public.appeals(id) on delete cascade,
  member_id   uuid not null references public.group_members(id),
  choice      text not null default 'pending',
  voted_at    timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint appeal_votes_choice_check
    check (choice in ('pending', 'in_favor', 'against', 'abstained')),
  unique (appeal_id, member_id)
);

alter table public.appeals      enable row level security;
alter table public.appeal_votes enable row level security;

-- Note: RLS policies, triggers, and RPCs are NOT recreated by this rollback.
-- Re-run 00014/00016 manually if a true rollforward is needed.
