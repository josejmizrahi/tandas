-- Mig 00180: group_members lifecycle metadata
--
-- Constitution Layer 2 (Membership). The table had two gaps:
--   (a) Soft-delete via `active=false` lost the "when". To reconstruct
--       "who was a member at the time of event X" you had to join to
--       system_events.memberLeft, which is fragile + expensive.
--   (b) No provenance: rows didn't say whether they came from
--       create_group_with_admin (founder seed), join_group_by_code
--       (invite link), or some other path. Blocks invite analytics +
--       audit of growth.
--
-- This adds:
--   left_at                   timestamptz null  — stamped on active→false
--   joined_via                text         null — 'founder_seed' | 'invite_code' | 'admin_add' | 'unknown'
--   joined_via_invite_code    text         null — actual invite code used (when joined_via='invite_code')
--
-- Stamping is trigger-driven so we don't have to chase every writer:
--   - BEFORE UPDATE OF active: if true→false, set left_at := now().
--                              if false→true (reactivation), clear left_at.
--   - BEFORE INSERT (deriving joined_via): if NULL on insert, derive:
--     user_id = groups.created_by → 'founder_seed', else 'unknown'.
--     Explicit callers (join_group_by_code) override the default.
--
-- One RPC patch: `join_group_by_code` stamps joined_via='invite_code' and
-- joined_via_invite_code=p_code on the inserted row. The reactivation
-- path keeps the original joined_via untouched — that's the true origin.

-- 1) Columns
alter table public.group_members
  add column if not exists left_at timestamptz,
  add column if not exists joined_via text
    check (joined_via in ('founder_seed', 'invite_code', 'admin_add', 'unknown')),
  add column if not exists joined_via_invite_code text;

create index if not exists group_members_left_at_idx
  on public.group_members (left_at)
  where left_at is not null;

comment on column public.group_members.left_at is
  'Timestamp the member transitioned to active=false. Null for active members. Stamped by trigger.';
comment on column public.group_members.joined_via is
  'Provenance: how this member joined. Values: founder_seed (created with group), invite_code, admin_add, unknown.';
comment on column public.group_members.joined_via_invite_code is
  'When joined_via=invite_code, the actual code used (snapshot — invite codes rotate).';

-- 2) Triggers
create or replace function public.stamp_member_left_at()
returns trigger language plpgsql set search_path = public, pg_temp
as $$
begin
  if old.active = true and new.active = false then
    new.left_at := coalesce(new.left_at, now());
  elsif old.active = false and new.active = true then
    -- Reactivation: clear left_at so the projection of "currently a
    -- member" matches reality. Historical records of past leaves live
    -- in system_events.memberLeft, not here.
    new.left_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists group_members_stamp_left_at on public.group_members;
create trigger group_members_stamp_left_at
  before update of active on public.group_members
  for each row execute function public.stamp_member_left_at();

create or replace function public.stamp_member_joined_via()
returns trigger language plpgsql set search_path = public, pg_temp
as $$
declare
  v_created_by uuid;
begin
  if new.joined_via is not null then
    return new;
  end if;

  select created_by into v_created_by
    from public.groups
   where id = new.group_id;

  if new.user_id = v_created_by then
    new.joined_via := 'founder_seed';
  else
    new.joined_via := 'unknown';
  end if;
  return new;
end;
$$;

drop trigger if exists group_members_stamp_joined_via on public.group_members;
create trigger group_members_stamp_joined_via
  before insert on public.group_members
  for each row execute function public.stamp_member_joined_via();

-- 3) Backfill
-- 3a) left_at: best-effort from latest memberLeft event for the user
update public.group_members gm
   set left_at = sub.occurred_at
  from (
    select se.group_id,
           (se.payload->>'user_id')::uuid as user_id,
           max(se.occurred_at) as occurred_at
      from public.system_events se
     where se.event_type = 'memberLeft'
       and se.payload->>'user_id' is not null
     group by se.group_id, se.payload->>'user_id'
  ) sub
 where gm.group_id = sub.group_id
   and gm.user_id  = sub.user_id
   and gm.active   = false
   and gm.left_at  is null;

-- 3b) joined_via: founder rows get founder_seed, everyone else unknown
update public.group_members gm
   set joined_via = case
     when gm.user_id = g.created_by then 'founder_seed'
     else 'unknown'
   end
  from public.groups g
 where gm.group_id = g.id
   and gm.joined_via is null;

-- 4) Patch join_group_by_code to stamp provenance.
-- Body is identical to mig 00098 except for the INSERT clause that
-- carries joined_via + joined_via_invite_code. Reactivation path does
-- NOT touch joined_via — that records the *original* arrival.
create or replace function public.join_group_by_code(p_code text)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  v_max int;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'auth required'; end if;
  select * into g from public.groups where invite_code = p_code;
  if not found then raise exception 'invite code not found'; end if;

  if exists (select 1 from public.group_members where group_id = g.id and user_id = v_uid) then
    -- Reactivation: was a member, left, rejoined via code. Still emit
    -- memberJoined so the timeline reflects the (re-)arrival.
    update public.group_members set active = true where group_id = g.id and user_id = v_uid;
    perform public.record_system_event(
      g.id,
      'memberJoined',
      null,
      null,
      jsonb_build_object('user_id', v_uid, 'reactivated', true)
    );
    return g;
  end if;

  select coalesce(max(turn_order), 0) into v_max from public.group_members where group_id = g.id;
  insert into public.group_members (group_id, user_id, role, turn_order, joined_via, joined_via_invite_code)
    values (g.id, v_uid, 'member', v_max + 1, 'invite_code', p_code);

  perform public.record_system_event(
    g.id,
    'memberJoined',
    null,
    null,
    jsonb_build_object('user_id', v_uid, 'reactivated', false)
  );

  return g;
end;
$$;
