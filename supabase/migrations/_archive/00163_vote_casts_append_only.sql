-- 00163 — vote_casts canonical append-only refactor (Constitution §7).
--
-- Why
-- ===
-- Constitution Article 7 lists `vote_casts` as a canonical atom:
-- "Append-only, sin UPDATE/DELETE, protegidos por trigger *_atom_guard."
-- But the live shape was mutable: start_vote pre-seeded one row per
-- eligible member with `choice='pending'`, and cast_vote UPDATE-ed the
-- row to the actual choice. Re-cast was an idempotent UPDATE of the same
-- row. AtomProjection.md classified the table as Atom; mig 00103
-- explicitly deferred its guard because cast_vote needed UPDATE.
--
-- This migration adopts the canonical atom pattern already in use for
-- `rsvp_actions` and `check_in_actions`: every state change is a new row,
-- and projections compute "latest per (vote, member)" to derive the
-- current ballot.
--
-- Refactor surface
-- ================
-- - Drop UNIQUE(vote_id, member_id). Multiple rows per (vote, member)
--   are now expected (one pending pre-seed + one or more casts).
-- - Drop `vote_casts_set_updated_at` BEFORE UPDATE trigger — append-only
--   tables don't get UPDATEs.
-- - Rewrite `vote_casts_resolve_user_action` from AFTER UPDATE to AFTER
--   INSERT (firing only when `choice <> 'pending'` so the pending
--   pre-seed doesn't trigger inbox-resolution).
-- - Rewrite `cast_vote` from UPDATE to INSERT. start_vote still pre-seeds
--   pending rows so the eligibility snapshot is preserved.
-- - Rewrite `vote_counts_view` to aggregate over the latest row per
--   (vote, member). Pending counts members whose latest row is still
--   `pending` (never cast).
-- - Rewrite `finalize_vote` to:
--     (a) count using the same latest-per-member projection,
--     (b) dedup the notifications_outbox bulk-insert to one row per
--         member (a member with N rows now exists; only the latest is
--         relevant).
-- - Add `vote_casts_atom_guard` BEFORE UPDATE OR DELETE using the shared
--   atom_no_mutation_guard function.
--
-- Empty-table luck
-- ================
-- vote_casts had zero rows at migration time (no votes in flight in
-- prod), so the cutover is clean — no backfill, no in-flight ballot
-- semantics to preserve.
--
-- iOS coordination
-- ================
-- LiveVoteCastRepository.myCast switched to
-- `.order("created_at", ascending: false).limit(1)` in a paired commit so
-- the latest row wins instead of arbitrary row from limit(1) on multiple
-- siblings.
--
-- Rollback
-- ========
-- _rollbacks/00163_rollback.sql restores the prior shape (with the legacy
-- mutable cast_vote / vote_counts_view / finalize_vote / resolve trigger).

-- =============================================================================
-- 1. Drop the unique constraint that blocked append-only inserts.
-- =============================================================================

alter table public.vote_casts
  drop constraint if exists vote_casts_vote_id_member_id_key;

-- =============================================================================
-- 2. Drop the BEFORE UPDATE timestamp trigger — pointless under append-only.
-- =============================================================================

drop trigger if exists vote_casts_set_updated_at on public.vote_casts;

-- =============================================================================
-- 3. Resolve-user-action trigger: AFTER UPDATE → AFTER INSERT (cast-only).
-- =============================================================================

create or replace function public.resolve_user_action_on_vote_cast()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  -- start_vote pre-seeds rows with choice='pending'; only act on actual
  -- ballots. The trigger's WHEN clause already filters, but the inner
  -- check is kept as a defensive belt-and-suspenders for any future
  -- trigger reattach.
  if NEW.choice = 'pending' then
    return NEW;
  end if;

  select user_id into v_user_id
  from public.group_members
  where id = NEW.member_id;

  if v_user_id is not null then
    update public.user_actions
    set resolved_at = now()
    where action_type in ('votePending', 'appealVotePending')
      and reference_id = NEW.vote_id
      and user_id = v_user_id
      and resolved_at is null;
  end if;
  return NEW;
end;
$$;

comment on function public.resolve_user_action_on_vote_cast() is
  'Auto-resolves votePending / appealVotePending user_actions when a member casts. Fires AFTER INSERT (post-mig 00163 append-only refactor) only on rows with choice <> pending.';

drop trigger if exists vote_casts_resolve_user_action on public.vote_casts;

create trigger vote_casts_resolve_user_action
  after insert on public.vote_casts
  for each row when (NEW.choice <> 'pending')
  execute function public.resolve_user_action_on_vote_cast();

-- =============================================================================
-- 4. cast_vote: UPDATE → INSERT (append-only).
-- =============================================================================

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

  -- Lock the vote row so cast_vote / finalize_vote serialize per vote.
  -- Preserves the FOR KEY SHARE pattern from mig 00138 (W1 E-1.3 race fix)
  -- while we mutate the children.
  select status, group_id into v_vote_status, v_group_id
  from public.votes where id = p_vote_id for key share;

  if v_vote_status is null then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote_status <> 'open' then
    raise exception 'vote is not open' using errcode = '22023';
  end if;

  select id into v_caller_member_id
  from public.group_members
  where group_id = v_group_id
    and user_id  = v_caller_id
    and active   = true;

  if v_caller_member_id is null then
    raise exception 'not eligible to vote' using errcode = '42501';
  end if;

  -- Append-only: every cast (including re-cast) is a new row. Latest
  -- per (vote, member) wins in vote_counts_view + finalize_vote.
  insert into public.vote_casts (vote_id, member_id, choice, cast_at)
  values (p_vote_id, v_caller_member_id, p_choice, now());

  -- Emit voteCast system event (unchanged from prior shape).
  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_group_id, 'voteCast', p_vote_id, v_caller_member_id,
    jsonb_build_object('choice', p_choice)
  );
end;
$$;

comment on function public.cast_vote(uuid, text) is
  'Records caller''s vote on an open vote. Append-only: every cast inserts a new vote_casts row; latest-per-(vote, member) wins. Re-cast supported by inserting another row (constitution §7 atom semantics).';

-- =============================================================================
-- 5. vote_counts_view: latest-per-(vote, member) aggregation.
-- =============================================================================

create or replace view public.vote_counts_view as
with latest_per_member as (
  select distinct on (vote_id, member_id)
    vote_id, member_id, choice
  from public.vote_casts
  order by vote_id, member_id, created_at desc, id desc
)
select
  vote_id,
  count(*) filter (where choice = 'in_favor')  as in_favor,
  count(*) filter (where choice = 'against')   as against,
  count(*) filter (where choice = 'abstained') as abstained,
  count(*) filter (where choice = 'pending')   as pending,
  count(*)                                      as total_eligible
from latest_per_member
group by vote_id;

comment on view public.vote_counts_view is
  'Aggregated vote counts per vote_id. Uses DISTINCT ON to fold the append-only vote_casts atom (mig 00163) down to one row per (vote, member). Reads bypass vote_casts RLS so anonymity is preserved.';

-- =============================================================================
-- 6. finalize_vote: count latest-per-member + dedup outbox fan-out.
-- =============================================================================

create or replace function public.finalize_vote(p_vote_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    v_vote                public.votes%rowtype;
    v_in_favor            int;
    v_against             int;
    v_abstained           int;
    v_pending             int;
    v_total               int;
    v_voted               int;
    v_quorum_count        int;
    v_resolution          text;
    v_fine_id             uuid;
    v_fine_user_id        uuid;
    v_fine_resource_id    uuid;
    v_fine_member_id      uuid;
    v_fine_updated        int;
    v_founder_user_id     uuid;
    v_founder_member_id   uuid;
    v_rule_id             uuid;
    v_rule_name           text;
    v_current_amount      int;
    v_proposed_amount     int;
    v_fine                public.fines;
begin
    select * into v_vote from public.votes where id = p_vote_id for update;
    if not found then raise exception 'vote not found' using errcode = '02000'; end if;
    if v_vote.status <> 'open' then
        return coalesce(v_vote.payload->>'resolution', 'unknown');
    end if;

    -- Append-only refactor (mig 00163): fold to latest-per-member, then
    -- count. A member with multiple rows (pending pre-seed + 1+ casts)
    -- contributes once based on their latest choice.
    with latest_per_member as (
      select distinct on (member_id) member_id, choice
      from public.vote_casts
      where vote_id = p_vote_id
      order by member_id, created_at desc, id desc
    )
    select
        count(*) filter (where choice = 'in_favor'),
        count(*) filter (where choice = 'against'),
        count(*) filter (where choice = 'abstained'),
        count(*) filter (where choice = 'pending'),
        count(*)
    into v_in_favor, v_against, v_abstained, v_pending, v_total
    from latest_per_member;

    v_voted := v_in_favor + v_against + v_abstained;
    v_quorum_count := greatest(
        ceil(v_total::numeric * v_vote.quorum_percent / 100)::int,
        v_vote.quorum_min_absolute
    );

    if v_voted < v_quorum_count then
        v_resolution := 'quorum_failed';
    elsif v_in_favor::numeric * 100 >= (v_in_favor + v_against)::numeric * v_vote.threshold_percent then
        v_resolution := 'passed';
    else
        v_resolution := 'failed';
    end if;

    update public.votes
    set status = case when v_resolution = 'quorum_failed' then 'quorum_failed' else 'resolved' end,
        resolved_at = now(),
        counts = jsonb_build_object(
            'inFavor', v_in_favor, 'against', v_against, 'abstained', v_abstained,
            'pending', v_pending, 'totalEligible', v_total,
            'quorumRequired', v_quorum_count, 'resolution', v_resolution
        ),
        payload = payload || jsonb_build_object('resolution', v_resolution)
    where id = p_vote_id;

    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (
        v_vote.group_id, 'voteResolved', p_vote_id, null,
        jsonb_build_object('vote_type', v_vote.vote_type, 'reference_id', v_vote.reference_id, 'resolution', v_resolution)
    );

    -- One outbox row per eligible member. Pre-refactor this fan-out used
    -- vote_casts directly (one row per member thanks to the unique
    -- constraint). Post-refactor multiple rows per member exist, so we
    -- dedupe to one notification each.
    insert into public.notifications_outbox (
        group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
        v_vote.group_id, vc.member_id, 'voteResolved',
        jsonb_build_object(
            'vote_id', p_vote_id, 'vote_type', v_vote.vote_type,
            'reference_id', v_vote.reference_id, 'resolution', v_resolution, 'title', v_vote.title
        ),
        'ruul://vote/' || p_vote_id::text
    from (
      select distinct member_id from public.vote_casts where vote_id = p_vote_id
    ) vc;

    if v_vote.vote_type = 'fine_appeal' then
        insert into public.notifications_outbox (
            group_id, recipient_member_id, notification_type, payload, deep_link
        )
        select
            v_vote.group_id, (v_vote.payload->>'member_id')::uuid, 'voteResolved',
            jsonb_build_object(
                'vote_id', p_vote_id, 'vote_type', v_vote.vote_type,
                'reference_id', v_vote.reference_id, 'resolution', v_resolution,
                'title', v_vote.title, 'is_appellant', true
            ),
            'ruul://vote/' || p_vote_id::text
        where v_vote.payload ? 'member_id'
          and (v_vote.payload->>'member_id') <> '';
    end if;

    -- fine_appeal side-effects: void the fine when the appeal passes.
    -- Pre-refactor lived inline; preserve the same logic post-append-only.
    if v_vote.vote_type = 'fine_appeal' and v_resolution = 'passed' then
        v_fine_id := v_vote.reference_id;
        if v_fine_id is not null then
            select * into v_fine from public.fines where id = v_fine_id;
            if v_fine.id is not null then
                v_fine_user_id     := v_fine.user_id;
                v_fine_resource_id := v_fine.resource_id;
                select id into v_fine_member_id from public.group_members
                  where group_id = v_fine.group_id and user_id = v_fine_user_id;

                -- Emit fine_voided atom (mirrors void_fine RPC).
                insert into public.ledger_entries (
                  group_id, type, from_member_id, amount_cents, metadata
                ) values (
                  v_fine.group_id, 'fine_voided', v_fine_member_id,
                  (v_fine.amount * 100)::bigint,
                  jsonb_build_object('fine_id', v_fine_id, 'reason', 'appeal_passed', 'vote_id', p_vote_id)
                );
            end if;
        end if;
    end if;

    -- rule_change side-effects: bump the rule amount when proposal passes.
    if v_vote.vote_type = 'rule_change' and v_resolution = 'passed' then
        v_current_amount  := nullif(v_vote.payload->>'current_amount', '')::int;
        v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;
        v_rule_id         := nullif(v_vote.payload->>'rule_id', '')::uuid;
        if v_current_amount is not null and v_proposed_amount is not null and v_rule_id is not null then
            update public.rules
            set consequences = jsonb_set(
                consequences,
                '{0,config,amount}',
                to_jsonb(v_proposed_amount),
                true
            )
            where id = v_rule_id;
        end if;
    end if;

    return v_resolution;
end;
$$;

comment on function public.finalize_vote(uuid) is
  'Closes a vote, derives resolution from latest-per-member vote_casts (append-only post-mig 00163), emits voteResolved system event + per-member notifications, and applies fine_appeal / rule_change side-effects.';

-- =============================================================================
-- 7. start_vote: unchanged semantics, but the pre-seed of pending rows
--    now lives alongside future append-only inserts. UNIQUE constraint
--    is gone, so duplicate pre-seeds would in principle insert extra
--    pending rows; the existing start_vote runs once per vote so this
--    is not a practical risk. Leaving the function as-is in this
--    migration to keep the change surface minimal.
-- =============================================================================

-- =============================================================================
-- 8. Atom guard: BEFORE UPDATE OR DELETE → reject.
-- =============================================================================

drop trigger if exists vote_casts_atom_guard on public.vote_casts;
create trigger vote_casts_atom_guard
  before update or delete on public.vote_casts
  for each row execute function public.atom_no_mutation_guard();

comment on trigger vote_casts_atom_guard on public.vote_casts is
  'Constitution §7 enforcement. vote_casts is append-only post-mig 00163; cast_vote inserts a new row per cast, never updates.';
