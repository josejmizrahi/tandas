-- 00052 — start_fine_appeal helper RPC.
-- (Originally 00046; renamed in repo. Prod migration name remains
-- "00046_start_fine_appeal_helper" — applied 2026-05-08 22:26 UTC.)
--
-- Audit § 2.2 + § 5.2 item 7 — appeals/appeal_votes legacy → votes-only path.
--
-- Background:
-- ===========
-- 00014 introduced legacy `appeals` + `appeal_votes` tables with their own
-- start_appeal/cast_appeal_vote/close_appeal_vote RPCs. 00020 introduced the
-- generic votes/vote_casts schema with start_vote/cast_vote/finalize_vote.
-- 00023 wired the generic path with infractor exclusion and notification
-- outbox writes. iOS LiveAppealRepository, however, kept reading/writing
-- the legacy tables until this sprint.
--
-- This migration adds a thin helper that takes the iOS-side
-- AppealRepository semantics (`startAppeal(fineId, reason)`) and translates
-- them to the generic `start_vote(p_vote_type='fine_appeal', …)` flow.
--
-- Why a server helper instead of two iOS round-trips:
--   1. Atomic — group lookup + member_id lookup + vote creation in one tx.
--   2. Authorization centralized — the "only the fined user can appeal"
--      rule lives next to the data, not in iOS.
--   3. Side effects (fine.status flip, appealCreated system_event) bundled.
--
-- Companion migration 00047 drops the legacy appeals/appeal_votes tables
-- after iOS LiveAppealRepository ships using this helper.

create or replace function public.start_fine_appeal(
  p_fine_id uuid,
  p_reason  text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_uid uuid := auth.uid();
  v_fine       public.fines%rowtype;
  v_member_id  uuid;
  v_vote_id    uuid;
  v_title      text;
begin
  if v_caller_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if length(coalesce(p_reason, '')) < 2 then
    raise exception 'reason required' using errcode = '22023';
  end if;

  select * into v_fine from public.fines where id = p_fine_id;
  if not found then
    raise exception 'fine not found' using errcode = '02000';
  end if;

  if v_fine.user_id <> v_caller_uid then
    raise exception 'only the fined user can file an appeal' using errcode = '42501';
  end if;

  if v_fine.status not in ('officialized', 'in_appeal') then
    raise exception 'cannot appeal a fine in status %', v_fine.status using errcode = '22023';
  end if;

  -- Look up the infractor (= caller = appellant) member_id within the group.
  select id into v_member_id
  from public.group_members
  where group_id = v_fine.group_id
    and user_id  = v_caller_uid
    and active   = true;

  if v_member_id is null then
    raise exception 'caller is not an active member of the group' using errcode = '42501';
  end if;

  v_title := 'Apelación · $' || trim(to_char(v_fine.amount, 'FM999G999D00'));

  -- Delegate to the generic start_vote RPC. payload.member_id is the
  -- infractor's group_members.id; start_vote will exclude them from
  -- vote_casts. payload.reason is denormalized so AppealRepository can
  -- read it without joining fines.
  v_vote_id := public.start_vote(
    p_group_id     => v_fine.group_id,
    p_vote_type    => 'fine_appeal',
    p_reference_id => p_fine_id,
    p_title        => v_title,
    p_description  => p_reason,
    p_payload      => jsonb_build_object('member_id', v_member_id, 'reason', p_reason)
  );

  -- Flip the fine to in_appeal so UI shows the right state.
  update public.fines
    set status     = 'in_appeal',
        updated_at = now()
  where id = p_fine_id;

  -- Emit appealCreated for history feeds. Resource_id refers to the fine
  -- (the resource being contested, post-00041 polymorphism); future
  -- resource-typed fines will route correctly.
  perform public.record_system_event(
    v_fine.group_id,
    'appealCreated',
    p_fine_id,
    v_member_id,
    jsonb_build_object(
      'vote_id', v_vote_id,
      'amount',  v_fine.amount,
      'reason',  p_reason
    )
  );

  return v_vote_id;
end;
$$;

revoke execute on function public.start_fine_appeal(uuid, text) from public, anon;
grant  execute on function public.start_fine_appeal(uuid, text) to authenticated;

comment on function public.start_fine_appeal(uuid, text) is
  'Starts a fine_appeal vote (delegates to start_vote). Caller must be the fined user. Flips fine.status to in_appeal and emits appealCreated. Returns the vote id.';
