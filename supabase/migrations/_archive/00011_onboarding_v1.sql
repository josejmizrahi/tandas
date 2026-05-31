-- =========================================================
-- Migration 00011 — Onboarding V1
--
-- Adds columns to groups + group_members for onboarding-driven
-- configuration: cover, frequency, fines flag, rotation mode,
-- joined_at_event_count.
--
-- Adds tables: invites (per-recipient pending invites with phone),
-- otp_codes (internal, edge-function-only).
--
-- Adds RPCs: create_initial_rule, mark_invite_used.
--
-- Extends create_group_with_admin (00010) to accept p_cover_image_name.
--
-- Idempotent (safe to re-apply). Rollback in 00011_rollback.sql.
-- =========================================================

-- =========================================================
-- 1. groups: new configuration columns
-- =========================================================
alter table public.groups
  add column if not exists cover_image_name text,
  add column if not exists frequency_type text
    check (frequency_type is null or frequency_type in ('weekly','biweekly','monthly','unscheduled')),
  add column if not exists frequency_config jsonb not null default '{}'::jsonb,
  add column if not exists fines_enabled boolean not null default true,
  add column if not exists rotation_mode text not null default 'manual'
    check (rotation_mode in ('auto_order','manual','no_host'));

-- Sync rotation_enabled (legacy bool) ↔ rotation_mode (V1 enum) automatically.
create or replace function public.sync_rotation_fields()
returns trigger language plpgsql as $$
begin
  new.rotation_enabled := new.rotation_mode != 'no_host';
  return new;
end;
$$;

drop trigger if exists groups_sync_rotation on public.groups;
create trigger groups_sync_rotation
  before insert or update of rotation_mode on public.groups
  for each row execute function public.sync_rotation_fields();

-- Backfill rotation_mode from rotation_enabled for existing rows
-- (no-op if there are no rows; safe).
update public.groups
  set rotation_mode = case when rotation_enabled then 'manual' else 'no_host' end
  where rotation_mode is null;

-- =========================================================
-- 2. group_members: track per-member event counter for grace period
-- =========================================================
alter table public.group_members
  add column if not exists joined_at_event_count int not null default 0;

-- Convenience view exposing is_founder without storing it.
create or replace view public.group_members_with_founder as
select
  gm.*,
  (gm.role = 'admin' and gm.user_id = g.created_by) as is_founder
from public.group_members gm
join public.groups g on g.id = gm.group_id;

grant select on public.group_members_with_founder to authenticated;

-- =========================================================
-- 3. invites table: per-recipient pending invites (with phone)
-- =========================================================
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  invited_by uuid not null references auth.users(id) on delete cascade,
  phone_e164 text,
  used_at timestamptz,
  used_by_user_id uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now()
);

create index if not exists idx_invites_group on public.invites(group_id);
create index if not exists idx_invites_phone on public.invites(phone_e164) where phone_e164 is not null;
create unique index if not exists uq_invites_used_by on public.invites(used_by_user_id) where used_by_user_id is not null;

alter table public.invites enable row level security;

drop policy if exists invites_select_members on public.invites;
create policy invites_select_members on public.invites
  for select using (public.is_group_member(group_id, auth.uid()));

drop policy if exists invites_insert_admin on public.invites;
create policy invites_insert_admin on public.invites
  for insert with check (public.is_group_admin(group_id, auth.uid()));

drop policy if exists invites_update_admin on public.invites;
create policy invites_update_admin on public.invites
  for update using (public.is_group_admin(group_id, auth.uid()));

-- =========================================================
-- 4. invite_preview view: read-only group preview for /invite/<code> deep link.
--
-- Uses the existing groups.invite_code (single code per group). The
-- separate invites table is for per-recipient tracking (phone), but
-- the preview uses the group-level code so the link is shareable.
-- =========================================================
create or replace view public.invite_preview as
select
  g.id as group_id,
  g.name as group_name,
  g.cover_image_name,
  g.event_label,
  g.frequency_type,
  g.frequency_config,
  g.invite_code,
  g.created_at as group_created_at,
  (select count(*) from public.group_members gm where gm.group_id = g.id and gm.active) as member_count,
  (select array_agg(p.display_name order by gm.joined_at)
     from public.group_members gm
     join public.profiles p on p.id = gm.user_id
     where gm.group_id = g.id and gm.active
     limit 5) as recent_member_names
from public.groups g;

grant select on public.invite_preview to anon, authenticated;

-- =========================================================
-- 5. otp_codes: edge-function-only table for WhatsApp OTP storage
-- =========================================================
create table if not exists public.otp_codes (
  id uuid primary key default gen_random_uuid(),
  phone_e164 text not null,
  code_hash text not null,                  -- sha256 of (code + phone) — never store plaintext
  channel text not null check (channel in ('whatsapp','sms')),
  expires_at timestamptz not null,
  attempts int not null default 0,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_otp_codes_phone on public.otp_codes(phone_e164) where consumed_at is null;
create index if not exists idx_otp_codes_expiry on public.otp_codes(expires_at);

alter table public.otp_codes enable row level security;
-- No policies → only service_role (edge functions) can access. ✅

-- =========================================================
-- 6. RPCs
-- =========================================================

-- create_group_with_admin: extend (drop old, recreate with cover param)
drop function if exists public.create_group_with_admin(text, text, text, text, text);

create or replace function public.create_group_with_admin(
  p_name text,
  p_event_label text default null,
  p_currency text default 'MXN',
  p_timezone text default 'America/Mexico_City',
  p_group_type text default 'recurring_dinner',
  p_cover_image_name text default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;

  insert into public.groups (
    name, event_label, currency, timezone, group_type,
    cover_image_name, created_by
  ) values (
    p_name,
    coalesce(p_event_label, 'evento'),
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    coalesce(p_group_type, 'recurring_dinner'),
    p_cover_image_name,
    uid
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, active)
    values (g.id, uid, 'admin', true);

  return g;
end;
$$;

revoke execute on function public.create_group_with_admin(text, text, text, text, text, text) from public, anon;
grant  execute on function public.create_group_with_admin(text, text, text, text, text, text) to authenticated;

-- create_initial_rule: skip-the-vote, admin-only seed rule
create or replace function public.create_initial_rule(
  p_group_id uuid,
  p_code text,
  p_title text,
  p_description text,
  p_trigger jsonb,
  p_action jsonb
) returns public.rules
language plpgsql security definer set search_path = public as $$
declare r public.rules;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can seed rules';
  end if;
  insert into public.rules (
    group_id, code, title, description, trigger, action, status, enabled, proposed_by
  ) values (
    p_group_id, p_code, p_title, p_description, p_trigger, p_action, 'active', true, auth.uid()
  ) returning * into r;
  return r;
end;
$$;

revoke execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) from public, anon;
grant  execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) to authenticated;

-- mark_invite_used: invitee completes OTP, claims their invite slot
create or replace function public.mark_invite_used(p_invite_id uuid)
returns public.invites
language plpgsql security definer set search_path = public as $$
declare i public.invites;
begin
  update public.invites
    set used_at = now(), used_by_user_id = auth.uid()
    where id = p_invite_id and used_at is null and expires_at > now()
    returning * into i;
  if i.id is null then raise exception 'invite not available'; end if;
  return i;
end;
$$;

revoke execute on function public.mark_invite_used(uuid) from public, anon;
grant  execute on function public.mark_invite_used(uuid) to authenticated;

-- update_group_config: partial update of onboarding-relevant fields, admin-only.
-- Avoids a generic "update groups" pattern that would need 10 RLS columns.
create or replace function public.update_group_config(
  p_group_id uuid,
  p_event_label text default null,
  p_frequency_type text default null,
  p_frequency_config jsonb default null,
  p_fines_enabled boolean default null,
  p_rotation_mode text default null,
  p_cover_image_name text default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can update group config';
  end if;
  update public.groups
    set event_label       = coalesce(p_event_label, event_label),
        frequency_type    = case when p_frequency_type is not null then p_frequency_type else frequency_type end,
        frequency_config  = case when p_frequency_config is not null then p_frequency_config else frequency_config end,
        fines_enabled     = coalesce(p_fines_enabled, fines_enabled),
        rotation_mode     = coalesce(p_rotation_mode, rotation_mode),
        cover_image_name  = case when p_cover_image_name is not null then p_cover_image_name else cover_image_name end,
        updated_at        = now()
    where id = p_group_id
    returning * into g;
  return g;
end;
$$;

revoke execute on function public.update_group_config(uuid, text, text, jsonb, boolean, text, text) from public, anon;
grant  execute on function public.update_group_config(uuid, text, text, jsonb, boolean, text, text) to authenticated;
