-- 00044 — Auto-resolve user_actions on related state transitions.
--
-- Bug class found during Beta 1 smoke: several action_types had a
-- creator (RPC or trigger) but no resolver. Once the user "completed"
-- the action by mutating the underlying primitive, the user_action
-- stayed unresolved → ghost rows in HomeView's Pendientes section.
--
-- Coverage matrix before this migration:
--
--   action_type            creator                         resolver
--   appealVotePending      on_appeal_vote_seeded           on_appeal_vote_cast      ✓
--   votePending            cast_vote (since 00043)         vote_casts trigger       ✓
--   finePending            on_fine_officialized            (none)                   ✗
--   fineProposalReview     on_fine_inserted                (none)                   ✗
--   ruleChangeApplyPending finalize_vote (rule_change ok)  (none)                   ✗
--   vote auto-finalize     finalize_vote                   (none, leaks pendings)   ✗
--
-- This migration adds 4 triggers + a one-time backfill of any rows
-- whose resolution conditions are already met.
--
-- Idempotent: each function uses CREATE OR REPLACE; each trigger uses
-- DROP IF EXISTS / CREATE.

-- ============================================================================
-- 1) finePending → resolve when fine is paid, waived, voided or in_appeal
-- ============================================================================
create or replace function public.resolve_fine_pending_action()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (NEW.paid = true and (OLD.paid is null or OLD.paid = false))
     or (NEW.waived = true and (OLD.waived is null or OLD.waived = false))
     or (NEW.status in ('voided','in_appeal') and OLD.status not in ('voided','in_appeal')) then
    update public.user_actions
       set resolved_at = now()
     where action_type = 'finePending'
       and reference_id = NEW.id
       and resolved_at is null;
  end if;
  return NEW;
end;
$$;

comment on function public.resolve_fine_pending_action() is
  'Resolves finePending user_actions when the underlying fine is paid, waived, voided or moved to in_appeal.';

drop trigger if exists fines_resolve_fine_pending on public.fines;
create trigger fines_resolve_fine_pending
  after update on public.fines
  for each row execute function public.resolve_fine_pending_action();

-- ============================================================================
-- 2) fineProposalReview → resolve when no fines remain `proposed` on event
-- ============================================================================
-- reference_id of fineProposalReview = event_id (per on_fine_inserted).
-- Once the founder reviewed every proposed fine on that event (each
-- transitioned to officialized or voided), the review row should resolve.
create or replace function public.resolve_fine_proposal_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_remaining int;
begin
  v_event_id := coalesce(NEW.event_id, OLD.event_id);
  if v_event_id is null then return NEW; end if;

  select count(*) into v_remaining
    from public.fines
   where event_id = v_event_id and status = 'proposed';

  if v_remaining = 0 then
    update public.user_actions
       set resolved_at = now()
     where action_type = 'fineProposalReview'
       and reference_id = v_event_id
       and resolved_at is null;
  end if;
  return NEW;
end;
$$;

comment on function public.resolve_fine_proposal_review() is
  'Resolves fineProposalReview user_actions when zero fines remain in proposed status for the event.';

drop trigger if exists fines_resolve_proposal_review on public.fines;
create trigger fines_resolve_proposal_review
  after insert or update on public.fines
  for each row execute function public.resolve_fine_proposal_review();

-- ============================================================================
-- 3) ruleChangeApplyPending → resolve when rule consequences amount matches
-- ============================================================================
-- ruleChangeApplyPending.reference_id = vote.id; vote.reference_id = rule.id;
-- When the founder edits the rule and the new consequences amountMxn
-- matches the proposed_amount captured in the vote payload, the apply-
-- pending action resolves. If the founder applies a different amount
-- (overriding the vote), the action stays — they didn't apply the
-- voted change.
create or replace function public.resolve_rule_change_apply_pending()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_amount int;
begin
  if NEW.consequences is distinct from OLD.consequences then
    -- Pull the first 'fine' consequence's amountMxn (V1 shape).
    v_new_amount := nullif(NEW.consequences->0->>'amountMxn','')::int;

    if v_new_amount is not null then
      update public.user_actions ua
         set resolved_at = now()
        from public.votes v
       where ua.action_type = 'ruleChangeApplyPending'
         and ua.resolved_at is null
         and v.id = ua.reference_id
         and v.vote_type = 'rule_change'
         and v.reference_id = NEW.id
         and nullif(v.payload->>'proposed_amount','')::int = v_new_amount;
    end if;
  end if;
  return NEW;
end;
$$;

comment on function public.resolve_rule_change_apply_pending() is
  'Resolves ruleChangeApplyPending when the rule consequences amount matches the proposed_amount of a passed rule_change vote.';

drop trigger if exists rules_resolve_change_apply_pending on public.rules;
create trigger rules_resolve_change_apply_pending
  after update on public.rules
  for each row execute function public.resolve_rule_change_apply_pending();

-- ============================================================================
-- 4) Vote close (auto-finalize or admin force-close)
-- ============================================================================
-- When a vote leaves status='open', any unanswered votePending /
-- appealVotePending rows for that vote should resolve — members can no
-- longer cast, so the action is over regardless of cast_at.
create or replace function public.resolve_vote_actions_on_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.status = 'open' and NEW.status <> 'open' then
    update public.user_actions
       set resolved_at = now()
     where action_type in ('votePending','appealVotePending')
       and reference_id = NEW.id
       and resolved_at is null;
  end if;
  return NEW;
end;
$$;

comment on function public.resolve_vote_actions_on_close() is
  'Resolves any leftover votePending/appealVotePending when the vote leaves open state.';

drop trigger if exists votes_resolve_actions_on_close on public.votes;
create trigger votes_resolve_actions_on_close
  after update on public.votes
  for each row execute function public.resolve_vote_actions_on_close();

-- ============================================================================
-- One-time backfill
-- ============================================================================

update public.user_actions ua
   set resolved_at = now()
  from public.fines f
 where ua.action_type = 'finePending'
   and ua.reference_id = f.id
   and ua.resolved_at is null
   and (f.paid = true or f.waived = true or f.status in ('voided','in_appeal'));

update public.user_actions ua
   set resolved_at = now()
 where ua.action_type = 'fineProposalReview'
   and ua.resolved_at is null
   and not exists (
     select 1 from public.fines f
      where f.event_id = ua.reference_id and f.status = 'proposed'
   );

update public.user_actions ua
   set resolved_at = now()
  from public.votes v
 where ua.action_type in ('votePending','appealVotePending')
   and ua.reference_id = v.id
   and ua.resolved_at is null
   and v.status <> 'open';
