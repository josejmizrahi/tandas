-- 00016 — Fines v2: status column + auto user_actions + fine_review_periods seed
--
-- Sprint 1c. The Sprint 1a edge-fn rule engine inserts proposed fines but the
-- legacy `fines` table doesn't have a `status` column — state is encoded in
-- the paid/waived flags. We add an explicit status column + backfill so the
-- new flow has clean semantics: proposed → officialized → paid (or voided
-- via appeal).
--
-- Also adds two database triggers:
--   1. After a fine is inserted (auto_generated): seed a fine_review_periods
--      row with 24h grace + user_action(fineProposalReview) for the host.
--   2. After a fine status flips to 'officialized': user_action(finePending)
--      for the fined user_id.
--
-- And a new RPC `officialize_fine` for the host to early-officialize a
-- proposed fine without waiting for the cron.

-- =============================================================================
-- 1. fines.status column + backfill
-- =============================================================================

alter table public.fines
  add column if not exists status text not null default 'proposed';

do $$ begin
  if not exists (
    select 1 from information_schema.constraint_column_usage
     where table_name = 'fines' and constraint_name = 'fines_status_check'
  ) then
    alter table public.fines
      add constraint fines_status_check
      check (status in ('proposed', 'officialized', 'paid', 'voided', 'in_appeal'));
  end if;
end $$;

-- Backfill existing rows. Pre-Sprint 1c fines were always officialized
-- (no grace concept), so:
--   paid=true   → 'paid'
--   waived=true → 'voided'
--   else        → 'officialized'
update public.fines set status = 'paid'
  where paid = true and status = 'proposed';
update public.fines set status = 'voided'
  where waived = true and paid = false and status = 'proposed';
update public.fines set status = 'officialized'
  where paid = false and waived = false and status = 'proposed' and auto_generated = false;

create index if not exists idx_fines_user_status
  on public.fines(user_id, status)
  where status in ('proposed', 'officialized');
create index if not exists idx_fines_group_status
  on public.fines(group_id, status);

-- =============================================================================
-- 2. user_actions trigger — auto-insert when a proposed fine arrives
-- =============================================================================

create or replace function public.on_fine_inserted()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_host_user_id uuid;
begin
  -- Only auto-generated fines go through the 24h grace period. Manual fines
  -- created via issue_manual_fine bypass it (host is the sole reviewer).
  if new.auto_generated and new.status = 'proposed' then
    insert into public.fine_review_periods (event_id, expires_at)
    values (new.event_id, now() + interval '24 hours')
    on conflict (event_id) do nothing;

    -- Notify the event host (one row per event, not per fine) so the inbox
    -- shows a single "Revisa N multas propuestas" entry.
    select host_id into v_host_user_id
      from public.events
     where id = new.event_id;

    if v_host_user_id is not null then
      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      ) values (
        v_host_user_id, new.group_id, 'fineProposalReview', new.event_id,
        'Revisa multas propuestas',
        'Las multas se oficializan en 24 horas si no las revisas',
        'high'
      ) on conflict do nothing;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists fines_after_insert_user_action on public.fines;
create trigger fines_after_insert_user_action
  after insert on public.fines
  for each row execute function public.on_fine_inserted();

-- Trigger: when a fine flips to officialized, queue an inbox entry for the
-- fined user. Fires whether the cron does it (finalize-fine-reviews) or the
-- host calls officialize_fine() manually.
create or replace function public.on_fine_officialized()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'proposed' and new.status = 'officialized' then
    insert into public.user_actions (
      user_id, group_id, action_type, reference_id,
      title, body, priority
    ) values (
      new.user_id, new.group_id, 'finePending', new.id,
      'Multa pendiente: $' || trim(to_char(new.amount, 'FM999G999D00')),
      new.reason,
      'high'
    );

    -- Emit fineOfficialized system_event so any future rules reacting to
    -- "member has multiple fines" can chain.
    perform public.record_system_event(
      new.group_id,
      'fineOfficialized',
      new.id,
      null,
      jsonb_build_object('amount', new.amount, 'rule_id', new.rule_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists fines_after_status_change on public.fines;
create trigger fines_after_status_change
  after update of status on public.fines
  for each row execute function public.on_fine_officialized();

-- =============================================================================
-- 3. user_actions trigger for appeal_votes — eligible voters get inbox row
-- =============================================================================

create or replace function public.on_appeal_vote_seeded()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid;
  v_group_id uuid;
  v_appellant_name text;
begin
  -- Only seed inbox rows for `pending` ballots (not already-voted ones).
  if new.choice <> 'pending' then return new; end if;

  select gm.user_id, f.group_id, p.display_name
    into v_user_id, v_group_id, v_appellant_name
    from public.appeal_votes av
    join public.appeals a       on a.id = av.appeal_id
    join public.fines f         on f.id = a.fine_id
    join public.group_members gm on gm.id = av.member_id
    left join public.profiles p  on p.id = a.appellant_member_id
   where av.id = new.id;

  if v_user_id is null then return new; end if;

  insert into public.user_actions (
    user_id, group_id, action_type, reference_id,
    title, body, priority
  ) values (
    v_user_id, v_group_id, 'appealVotePending', new.appeal_id,
    'Vota una apelación',
    coalesce(v_appellant_name, 'Un miembro') || ' apeló su multa',
    'high'
  ) on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists appeal_votes_after_insert on public.appeal_votes;
create trigger appeal_votes_after_insert
  after insert on public.appeal_votes
  for each row execute function public.on_appeal_vote_seeded();

-- When a vote is cast (choice flips from pending), resolve that user's
-- pending action so the inbox stays clean.
create or replace function public.on_appeal_vote_cast()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_user_id uuid;
begin
  if old.choice = 'pending' and new.choice <> 'pending' then
    select gm.user_id into v_user_id
      from public.group_members gm
     where gm.id = new.member_id;
    if v_user_id is not null then
      update public.user_actions
         set resolved_at = now()
       where user_id = v_user_id
         and action_type = 'appealVotePending'
         and reference_id = new.appeal_id
         and resolved_at is null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists appeal_votes_after_choice_change on public.appeal_votes;
create trigger appeal_votes_after_choice_change
  after update of choice on public.appeal_votes
  for each row execute function public.on_appeal_vote_cast();

-- =============================================================================
-- 4. RPCs — officialize_fine, void_fine, pay_fine_v2
-- =============================================================================

create or replace function public.officialize_fine(p_fine_id uuid)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;

  -- Only the event host (or group admin) can early-officialize.
  select * into f from public.fines where id = p_fine_id;
  if f.id is null then raise exception 'fine not found'; end if;
  if f.status <> 'proposed' then
    raise exception 'fine status is %, must be proposed', f.status;
  end if;
  if not (
    public.is_group_admin(f.group_id, uid)
    or exists (
      select 1 from public.events e
       where e.id = f.event_id and e.host_id = uid
    )
  ) then
    raise exception 'only host or admin can officialize this fine';
  end if;

  update public.fines set status = 'officialized' where id = p_fine_id
    returning * into f;

  -- Mark fine_review_periods done if all event fines are officialized.
  update public.fine_review_periods
     set officialized_at = now(), officialized_by = (
       select id from public.group_members where user_id = uid and group_id = f.group_id limit 1
     )
   where event_id = f.event_id and officialized_at is null;

  return f;
end;
$$;

create or replace function public.void_fine(p_fine_id uuid, p_reason text default null)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into f from public.fines where id = p_fine_id;
  if f.id is null then raise exception 'fine not found'; end if;
  if not public.is_group_admin(f.group_id, uid) then
    raise exception 'only admins can void fines';
  end if;
  update public.fines
     set status = 'voided',
         waived = true,
         waived_at = now(),
         waived_reason = p_reason
   where id = p_fine_id
   returning * into f;
  return f;
end;
$$;

revoke execute on function public.officialize_fine(uuid) from public, anon;
revoke execute on function public.void_fine(uuid, text) from public, anon;
grant  execute on function public.officialize_fine(uuid) to authenticated;
grant  execute on function public.void_fine(uuid, text) to authenticated;
