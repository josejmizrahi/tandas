-- Mig 00196: notify affected member when their expense gets reversed.
--
-- Closes the UX loop of mig 00195 (ledger_review auto-reversal). When the
-- vote resolves `failed` and the trigger emits the reimbursement, ALSO
-- enqueue a personal notification to the original recorder (the spender)
-- so they don't only learn about the reversal by checking activity.
--
-- Implementation: extend `ledger_review_apply_resolution` to insert into
-- `notifications_outbox`. The `dispatch-notifications-every-minute` cron
-- picks it up and pushes via APNs. Recipient is the group_members row
-- for the original `recorded_by` (auth.users.id → group_members.id).

create or replace function public.ledger_review_apply_resolution()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_orig       public.ledger_entries;
  v_resolution text;
  v_recipient  uuid;
begin
  if NEW.vote_type <> 'ledger_review' then return NEW; end if;
  if OLD.status = NEW.status then return NEW; end if;
  if NEW.status <> 'resolved' then return NEW; end if;
  v_resolution := NEW.payload->>'resolution';
  if v_resolution <> 'failed' then return NEW; end if;

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

  -- Insert the reimbursement. Same as mig 00195.
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

  -- Mig 00196: notify the affected member. Resolve auth.users.id
  -- (v_orig.recorded_by) to group_members.id. Skip silently if the
  -- recorder has left the group — they won't see the push, but the
  -- reversal still applied.
  select gm.id into v_recipient
  from public.group_members gm
  where gm.group_id = v_orig.group_id
    and gm.user_id  = v_orig.recorded_by
  limit 1;

  if v_recipient is not null then
    insert into public.notifications_outbox (
      group_id, recipient_member_id, notification_type, payload, deep_link
    ) values (
      v_orig.group_id,
      v_recipient,
      'expenseReversed',
      jsonb_build_object(
        'vote_id',                  NEW.id,
        'vote_title',               NEW.title,
        'reversed_ledger_entry_id', v_orig.id,
        'amount_cents',             v_orig.amount_cents,
        'currency',                 v_orig.currency,
        'resolution',               'failed'
      ),
      'ruul://vote/' || NEW.id::text
    );
  end if;

  return NEW;
end;
$function$;

comment on function public.ledger_review_apply_resolution() is
  'Auto-reverses a ledger_entry when its ledger_review vote resolves failed AND notifies the affected member. Inserts a reimbursement row + a notifications_outbox row to the recorder. The emit-atom guard (mig 00195) prevents the reversal from re-triggering the rule. Per mig 00196.';
