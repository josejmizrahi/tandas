-- 00138 — Beta 1 Consolidation W1-3: cast_vote serializes with finalize_vote.
--
-- The race
-- ========
-- finalize_vote (mig 00020, refined in 00123 v4) does:
--   1. BEGIN
--   2. SELECT * FROM votes WHERE id = X FOR UPDATE     ← locks votes row
--   3. SELECT count(*) FROM vote_casts WHERE vote_id = X ← UNLOCKED read
--   4. UPDATE votes SET status='resolved', counts=...
--   5. COMMIT
--
-- cast_vote (mig 00020) does:
--   1. BEGIN
--   2. SELECT status, group_id FROM votes WHERE id = X  ← UNLOCKED read
--   3. UPDATE vote_casts SET choice=..., cast_at=now()
--   4. INSERT system_events 'voteCast'
--   5. COMMIT
--
-- Under READ COMMITTED, finalize's FOR UPDATE on `votes` does NOT block
-- cast_vote's plain SELECT on `votes`. So this interleaving was possible:
--
--   T_finalize (cron):                    T_cast (user):
--   ─────────────────────                 ────────────────────────
--   BEGIN
--   SELECT votes FOR UPDATE              (status='open' visible)
--   SELECT count(vote_casts) = 9
--                                         BEGIN
--                                         SELECT votes.status = 'open' ✓
--                                         UPDATE vote_casts SET choice='in_favor'
--                                         COMMIT  ← cast persisted to DB
--   UPDATE votes SET status='resolved',
--                    counts={...,total=9}  ← stale tally, missing cast
--   COMMIT
--
-- Outcome: the cast was committed but NOT counted. For governance-
-- changing votes (rule_change, fine_appeal) this is fairness-breaking —
-- a vote can swing in the wrong direction silently.
--
-- The fix
-- =======
-- Make cast_vote acquire a row-level lock on `votes` that conflicts with
-- finalize_vote's FOR UPDATE. We use FOR KEY SHARE (the weakest of the
-- four PG row-level lock modes that still conflicts with FOR UPDATE):
--
--   FOR KEY SHARE × FOR KEY SHARE  : compatible (multiple casts in parallel OK)
--   FOR KEY SHARE × FOR UPDATE     : CONFLICT (cast serializes vs finalize)
--
-- Postgres lock-conflict matrix reference:
--   https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS
--
-- Three guarantees after this fix:
--
--   1. If finalize is already running when cast starts, cast's FOR KEY
--      SHARE blocks. When finalize commits, cast resumes, re-reads
--      votes.status (now 'resolved' / 'quorum_failed'), and raises
--      'vote is not open' to the user — never silently records into
--      a closed vote.
--
--   2. While cast holds FOR KEY SHARE, a concurrent finalize blocks at
--      its FOR UPDATE. Its subsequent COUNT(*) over vote_casts sees
--      the just-committed cast — no vote lost from the tally.
--
--   3. Multiple cast_vote calls on the SAME vote from DIFFERENT members
--      stay parallelizable (FOR KEY SHARE is compatible with itself).
--      Only finalize serializes — and finalize runs once per vote close.
--
-- Performance note: cast_vote already updates vote_casts (which is the
-- contended write per vote). The added FOR KEY SHARE on votes is a
-- short shared lock held for a couple of ms — negligible vs the writes
-- it already does. No measurable user-visible latency change.
--
-- Test (e2e/voteCastRace.test.ts) confirms:
--   - The lock structure (cast blocks when finalize holds the row).
--   - Race-free tally: 10 concurrent casts + 1 finalize → final
--     counts match actual vote_casts state.
--
-- Idempotent CREATE OR REPLACE — safe to re-run.

create or replace function public.cast_vote(
  p_vote_id uuid,
  p_choice  text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id        uuid;
  v_caller_member_id uuid;
  v_vote_status      text;
  v_group_id         uuid;
begin
  v_caller_id := auth.uid();
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if p_choice not in ('in_favor', 'against', 'abstained') then
    raise exception 'invalid choice' using errcode = '22023';
  end if;

  -- W1-3 fix: FOR KEY SHARE serializes against finalize_vote's FOR UPDATE.
  -- See migration comment for the full race analysis.
  select status, group_id
    into v_vote_status, v_group_id
    from public.votes
   where id = p_vote_id
   for key share;

  if v_vote_status is null then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote_status <> 'open' then
    raise exception 'vote is not open' using errcode = '22023';
  end if;

  -- Caller must be a member of the group
  select id into v_caller_member_id
    from public.group_members
   where group_id = v_group_id
     and user_id  = v_caller_id
     and active   = true;

  if v_caller_member_id is null then
    raise exception 'not eligible to vote' using errcode = '42501';
  end if;

  -- Update caster's row
  update public.vote_casts
     set choice  = p_choice,
         cast_at = now()
   where vote_id   = p_vote_id
     and member_id = v_caller_member_id;

  if not found then
    raise exception 'no ballot for this member on this vote' using errcode = '02000';
  end if;

  -- Emit system event
  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_group_id,
    'voteCast',
    p_vote_id,
    v_caller_member_id,
    jsonb_build_object('choice', p_choice)
  );
end;
$$;

comment on function public.cast_vote is
  'v2 (W1-3, mig 00138): takes FOR KEY SHARE on votes row to serialize against finalize_vote''s FOR UPDATE — prevents the race where a cast committed between finalize''s COUNT and UPDATE was silently lost. v1 (mig 00020): records caller''s vote_cast choice on an open vote. Idempotent: re-cast updates the existing row.';
