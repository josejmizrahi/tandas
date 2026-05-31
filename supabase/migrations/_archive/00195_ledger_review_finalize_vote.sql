-- Mig 00195: finalize_vote handler for ledger_review + reversal guard.
--
-- Extends mig 00194 (expense_threshold_vote Phase 1) to Phase 2: when a
-- ledger_review vote resolves with `failed`, automatically emit a
-- reimbursement ledger_entry that backs out the original. If it
-- resolves `passed` or `quorum_failed`, no-op (the original stays).
--
-- Two changes:
--   1. ledger_entries_emit_atom: skip emitting ledgerEntryCreated when
--      the row carries `metadata.reversed_ledger_entry_id`. System-
--      generated reversals must NOT re-trigger the rule that opened the
--      vote that caused them — that would be an infinite-vote-loop.
--   2. finalize_vote: new branch for `ledger_review` + `failed`. Reads
--      original, inserts reimbursement with linking metadata.

-- =============================================================================
-- 1. Trigger guard against reversal re-trigger
-- =============================================================================

create or replace function public.ledger_entries_emit_atom()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_member_id uuid;
begin
  -- Mig 00195: skip emission for system-generated reversals. They're
  -- already audited via the originating voteResolved atom; emitting
  -- ledgerEntryCreated again would let the same `expense_threshold_vote`
  -- rule re-fire and open a vote on the reversal (then the reversal of
  -- that reversal, etc.). The metadata signal is set by finalize_vote
  -- when it inserts a reimbursement to undo a failed ledger_review.
  if NEW.metadata ? 'reversed_ledger_entry_id' then
    return NEW;
  end if;

  select gm.id into v_member_id
  from public.group_members gm
  where gm.group_id = NEW.group_id
    and gm.user_id  = NEW.recorded_by
  limit 1;

  perform public.record_system_event(
    p_group_id    => NEW.group_id,
    p_event_type  => 'ledgerEntryCreated',
    p_resource_id => NEW.resource_id,
    p_member_id   => v_member_id,
    p_payload     => jsonb_build_object(
      'ledger_entry_id', NEW.id,
      'type',            NEW.type,
      'amount_cents',    NEW.amount_cents,
      'currency',        NEW.currency,
      'from_member_id',  NEW.from_member_id,
      'to_member_id',    NEW.to_member_id,
      'recorded_by',     NEW.recorded_by
    )
  );

  return NEW;
end;
$function$;

-- =============================================================================
-- 2. finalize_vote: ledger_review failed → reimbursement reversal
-- =============================================================================
-- Strategy: instead of rewriting the entire 200-line finalize_vote, we add
-- a small AFTER trigger on `votes` UPDATE that catches the resolved
-- transition for `ledger_review` and applies the side-effect. Same shape
-- as fine_voided side-effects historically lived inline, but adding via
-- a separate trigger keeps finalize_vote's plpgsql body untouched and
-- the side-effect testable independently.

create or replace function public.ledger_review_apply_resolution()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_orig public.ledger_entries;
  v_resolution text;
begin
  -- Only fire on the open → resolved transition for ledger_review votes
  -- with a `failed` resolution. Other vote_types and resolutions pass.
  if NEW.vote_type <> 'ledger_review' then return NEW; end if;
  if OLD.status = NEW.status then return NEW; end if;
  if NEW.status <> 'resolved' then return NEW; end if;
  v_resolution := NEW.payload->>'resolution';
  if v_resolution <> 'failed' then return NEW; end if;

  -- Look up original ledger entry. If it was deleted (shouldn't happen
  -- — ledger_entries is atom-like) or never existed, log + skip.
  select * into v_orig from public.ledger_entries where id = NEW.reference_id;
  if not found then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (
      NEW.group_id, 'voteResolved', NEW.id, null,
      jsonb_build_object(
        'vote_type', 'ledger_review',
        'resolution', 'failed',
        'reversal_skipped_reason', 'original_ledger_entry_not_found',
        'reference_id', NEW.reference_id
      )
    );
    return NEW;
  end if;

  -- Emit the reimbursement. Same amount + currency; from/to swapped so
  -- the original spender gets credited back. metadata.reversed_ledger_entry_id
  -- triggers the emit-atom guard so this row does NOT re-trigger
  -- expense_threshold_vote.
  insert into public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata, recorded_by
  ) values (
    v_orig.group_id,
    v_orig.resource_id,
    'reimbursement',
    v_orig.amount_cents,
    v_orig.currency,
    v_orig.to_member_id,
    v_orig.from_member_id,
    jsonb_build_object(
      'reversed_ledger_entry_id', v_orig.id,
      'reason',                   'ledger_review_failed',
      'vote_id',                  NEW.id
    ),
    v_orig.recorded_by
  );

  return NEW;
end;
$function$;

drop trigger if exists ledger_review_apply_resolution_trg on public.votes;

create trigger ledger_review_apply_resolution_trg
  after update on public.votes
  for each row execute function public.ledger_review_apply_resolution();

comment on function public.ledger_review_apply_resolution() is
  'Auto-reverses a ledger_entry when its ledger_review vote resolves `failed`. Inserts a reimbursement row with metadata.reversed_ledger_entry_id linking back to the original; the emit-atom guard prevents the reversal from re-triggering the rule. Per mig 00195 (expense_threshold_vote Phase 2).';
