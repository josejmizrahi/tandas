-- 00202 — fund operations slice: writers + balance projection + lifecycle.
--
-- (Filed as 00198 in the original PR; renumbered to 00202 because mig
-- 00198 was reused by `right_resource_canonical` shipped in parallel.
-- Supabase records migrations by version timestamp, not filename, so
-- the rename is metadata-only on the filesystem. Prod state unaffected.)
--
-- Builds on mig 00139 (create_fund) and mig 00136 (member balance views)
-- to ship the read + write surface that turns `resource_type='fund'` from
-- a thin enum case into a fully functional money resource.
--
-- Doctrine
-- ========
-- Constitution §8 + Plans/Active/AtomProjection.md: nothing about a fund
-- balance is persisted as independent state. Balance, contribution count,
-- expense count, last activity — all recompute from `public.ledger_entries`
-- on every read of `fund_balance_view`. Stale projection → recoverable;
-- rerun the view against the atom log is the canonical recovery path.
--
-- Constitution §11: every money atom lives in `public.ledger_entries`. The
-- writers here are thin SECURITY DEFINER wrappers over `record_ledger_entry`
-- (mig 00082) that bolt on fund-specific invariants (target resource is
-- type='fund', not archived, caller is member). The append-only guard from
-- mig 00103 keeps the atom log immutable downstream.
--
-- Changes
-- =======
--   1. `fundLocked` / `fundUnlocked` added to is_known_system_event_type
--      whitelist (mig 00193 was the last extension). Lock state is metadata
--      on `resources` — emitting an atom lets the rule engine react.
--
--   2. `public.fund_balance_view` — per-fund, per-currency projection.
--      Returns one row per (fund, currency) when there is activity,
--      and a single row with currency from metadata when there is none.
--      Direction-based balance math matches mig 00136 convention:
--         in_cents  = sum where from_member_id IS NOT NULL AND to IS NULL
--         out_cents = sum where from_member_id IS NULL     AND to IS NOT NULL
--         balance_cents = in - out
--      contribution_count / expense_count filter by `ledger_entries.type`
--      so the UI can render "5 aportaciones · 3 gastos" cheaply.
--
--   3. `fund_contribute(p_fund_id, p_amount_cents, p_currency?, p_note?)` —
--      records type='contribution' with from=caller_member, to=NULL. Any
--      group member can call. Currency falls through to fund.metadata.currency,
--      then to 'MXN'. Note (if provided) lands in entry metadata.
--
--   4. `fund_record_expense(p_fund_id, p_amount_cents, p_to_member_id,
--      p_currency?, p_note?)` — analogous OUT writer: type='expense',
--      from=NULL, to=p_to_member_id. `p_to_member_id` is required for V1
--      because direction-based balance math wouldn't register a vendor
--      expense (both nulls). Vendor expenses are out of scope for this
--      slice and would need a separate `fund_record_external_expense`
--      writer that bumps a balance counter explicitly.
--
--   5. `fund_lock(p_fund_id, p_reason?)` / `fund_unlock(p_fund_id)` —
--      admin-only. Stamps `locked_at` / `locked_by` / `locked_reason`
--      into `resources.metadata` and emits `fundLocked` / `fundUnlocked`.
--      The WRITERS THEMSELVES do not consult lock state. Per Constitution
--      §9, blocking-on-lock is rule behavior: a rule with trigger
--      `fundLocked` + consequence `blockLedgerEntry` (future shape) is
--      the policy-layer enforcement. The minimum-governance posture
--      chosen for this slice keeps RPC logic verifiable and reasoning
--      about side effects narrow.
--
-- Out of scope (intentional, follow-up slices):
--   - fund-scoped expense_threshold templates. The expense_threshold_warning
--     / expense_threshold_vote templates (mig 00193/00194) are group-scoped.
--     Fund-scoped variants would add new rows with scope_hint='resource'
--     and valid_resource_types=['fund'].
--   - `fund_archive` wrapper. Generic `archive_resource` (mig 00184) already
--     covers the soft-delete path and emits `resourceArchived` with
--     resource_type='fund' in the payload — that fulfills the canonical
--     spec's `fund.archived` atom requirement without duplication.
--   - Vendor (external) expenses with no recipient member.
--   - Multi-currency aggregation. The view returns one row per currency;
--     UI decides whether to surface multiple lines or pick the group's
--     primary currency.

-- =============================================================================
-- 1. Extend SystemEventType whitelist with fundLocked / fundUnlocked
-- =============================================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $function$
  -- Snapshot of the prod array at the time this migration was authored
  -- (post event_resource_links + event_cancelled_atom) plus the two new
  -- fund lock atoms. Preserving the full array on `create or replace`
  -- is mandatory — Postgres replaces the body wholesale, so omitting any
  -- entry silently drops support for that event_type at INSERT time
  -- (enforced by `system_events_event_type_known_chk`).
  select p_event_type = any (array[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'assetCreated',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    -- mig 00202: fund lock lifecycle
    'fundLocked', 'fundUnlocked'
  ]);
$function$;

-- =============================================================================
-- 2. fund_balance_view — per-fund, per-currency projection over ledger_entries
-- =============================================================================

create or replace view public.fund_balance_view
with (security_invoker = on)
as
with funds as (
  select id, group_id, metadata, archived_at, created_at
  from public.resources
  where resource_type = 'fund'
),
flows as (
  select
    le.resource_id as fund_id,
    le.currency,
    sum(case when le.from_member_id is not null and le.to_member_id is null
             then le.amount_cents else 0 end)::bigint                          as in_cents,
    sum(case when le.from_member_id is null and le.to_member_id is not null
             then le.amount_cents else 0 end)::bigint                          as out_cents,
    count(*) filter (where le.type = 'contribution')::bigint                   as contribution_count,
    count(*) filter (where le.type = 'expense')::bigint                        as expense_count,
    max(le.occurred_at)                                                        as last_activity_at
  from public.ledger_entries le
  join funds f on f.id = le.resource_id
  group by le.resource_id, le.currency
)
select
  f.id                                                              as fund_id,
  f.group_id,
  f.metadata->>'name'                                               as name,
  nullif(f.metadata->>'target_amount_cents','')::bigint             as target_amount_cents,
  coalesce(fl.currency, f.metadata->>'currency', 'MXN')             as currency,
  coalesce(fl.in_cents,  0)::bigint                                 as in_cents,
  coalesce(fl.out_cents, 0)::bigint                                 as out_cents,
  (coalesce(fl.in_cents, 0) - coalesce(fl.out_cents, 0))::bigint    as balance_cents,
  coalesce(fl.contribution_count, 0)::bigint                        as contribution_count,
  coalesce(fl.expense_count,      0)::bigint                        as expense_count,
  fl.last_activity_at,
  nullif(f.metadata->>'locked_at','')::timestamptz                  as locked_at,
  f.metadata->>'locked_reason'                                      as locked_reason,
  f.archived_at,
  f.created_at
from funds f
left join flows fl on fl.fund_id = f.id;

comment on view public.fund_balance_view is
  'Per-fund, per-currency projection over public.ledger_entries. balance_cents = in - out using the direction-based convention from mig 00136 (in = member→fund, out = fund→member). Funds with no flows return one row with currency from metadata. Funds with multi-currency activity return one row per currency. Surfaces locked_at / locked_reason / archived_at so callers can render lifecycle state without a second fetch. Constitution §8 — derived state, recomputed on every read. RLS via security_invoker; caller needs SELECT on resources + ledger_entries.';

-- =============================================================================
-- 3. fund_contribute RPC
-- =============================================================================

create or replace function public.fund_contribute(
  p_fund_id      uuid,
  p_amount_cents bigint,
  p_currency     text default null,
  p_note         text default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_uid            uuid := auth.uid();
  v_group_id       uuid;
  v_metadata       jsonb;
  v_archived       timestamptz;
  v_currency       text;
  v_caller_member  uuid;
  v_payload_meta   jsonb;
  v_entry          public.ledger_entries;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'contribution amount must be positive' using errcode = '22023';
  end if;

  select group_id, metadata, archived_at
    into v_group_id, v_metadata, v_archived
  from public.resources
  where id = p_fund_id
    and resource_type = 'fund';

  if v_group_id is null then
    raise exception 'fund not found' using errcode = 'check_violation';
  end if;

  if v_archived is not null then
    raise exception 'fund is archived' using errcode = 'check_violation';
  end if;

  if not public.is_group_member(v_group_id, v_uid) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  select id into v_caller_member
    from public.group_members
   where group_id = v_group_id
     and user_id  = v_uid
     and active   = true
   limit 1;

  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');
  v_payload_meta := case
    when p_note is null or length(trim(p_note)) = 0 then '{}'::jsonb
    else jsonb_build_object('note', trim(p_note))
  end;

  v_entry := public.record_ledger_entry(
    p_group_id       => v_group_id,
    p_resource_id    => p_fund_id,
    p_type           => 'contribution',
    p_amount_cents   => p_amount_cents,
    p_from_member_id => v_caller_member,
    p_to_member_id   => null,
    p_currency       => v_currency,
    p_metadata       => v_payload_meta
  );

  return v_entry;
end;
$$;

revoke execute on function public.fund_contribute(uuid, bigint, text, text) from public, anon;
grant  execute on function public.fund_contribute(uuid, bigint, text, text) to authenticated;

comment on function public.fund_contribute(uuid, bigint, text, text) is
  'Records a contribution to a fund. Validates resource is type=fund, not archived, amount > 0, caller is group member. Calls record_ledger_entry with type=contribution, from=caller_member, to=NULL, resource_id=fund. Currency falls through fund.metadata.currency then to MXN. Mig 00202.';

-- =============================================================================
-- 4. fund_record_expense RPC
-- =============================================================================

create or replace function public.fund_record_expense(
  p_fund_id        uuid,
  p_amount_cents   bigint,
  p_to_member_id   uuid,
  p_currency       text default null,
  p_note           text default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_uid            uuid := auth.uid();
  v_group_id       uuid;
  v_metadata       jsonb;
  v_archived       timestamptz;
  v_currency       text;
  v_payload_meta   jsonb;
  v_entry          public.ledger_entries;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'expense amount must be positive' using errcode = '22023';
  end if;

  if p_to_member_id is null then
    raise exception 'expense recipient required' using errcode = '22023';
  end if;

  select group_id, metadata, archived_at
    into v_group_id, v_metadata, v_archived
  from public.resources
  where id = p_fund_id
    and resource_type = 'fund';

  if v_group_id is null then
    raise exception 'fund not found' using errcode = 'check_violation';
  end if;

  if v_archived is not null then
    raise exception 'fund is archived' using errcode = 'check_violation';
  end if;

  if not public.is_group_member(v_group_id, v_uid) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');
  v_payload_meta := case
    when p_note is null or length(trim(p_note)) = 0 then '{}'::jsonb
    else jsonb_build_object('note', trim(p_note))
  end;

  v_entry := public.record_ledger_entry(
    p_group_id       => v_group_id,
    p_resource_id    => p_fund_id,
    p_type           => 'expense',
    p_amount_cents   => p_amount_cents,
    p_from_member_id => null,
    p_to_member_id   => p_to_member_id,
    p_currency       => v_currency,
    p_metadata       => v_payload_meta
  );

  return v_entry;
end;
$$;

revoke execute on function public.fund_record_expense(uuid, bigint, uuid, text, text) from public, anon;
grant  execute on function public.fund_record_expense(uuid, bigint, uuid, text, text) to authenticated;

comment on function public.fund_record_expense(uuid, bigint, uuid, text, text) is
  'Records an expense from a fund to a recipient member. Validates resource is type=fund, not archived, amount > 0, recipient is required, caller is group member. Calls record_ledger_entry with type=expense, from=NULL, to=p_to_member_id, resource_id=fund. Vendor expenses (no recipient) are out of scope for this slice — they would not register in the direction-based balance projection. Mig 00202.';

-- =============================================================================
-- 5. fund_lock / fund_unlock RPCs
-- =============================================================================

create or replace function public.fund_lock(
  p_fund_id  uuid,
  p_reason   text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_uid        uuid := auth.uid();
  v_group_id   uuid;
  v_archived   timestamptz;
  v_metadata   jsonb;
  v_locked_at  timestamptz;
  v_now        timestamptz := now();
  v_reason     text;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  select group_id, archived_at, metadata
    into v_group_id, v_archived, v_metadata
    from public.resources
   where id = p_fund_id
     and resource_type = 'fund'
   for update;

  if v_group_id is null then
    raise exception 'fund not found' using errcode = 'check_violation';
  end if;
  if v_archived is not null then
    raise exception 'fund is archived' using errcode = 'check_violation';
  end if;
  if not public.is_group_admin(v_group_id, v_uid) then
    raise exception 'caller is not a group admin' using errcode = '42501';
  end if;

  v_locked_at := nullif(v_metadata->>'locked_at','')::timestamptz;
  if v_locked_at is not null then
    raise exception 'fund is already locked' using errcode = 'check_violation';
  end if;

  v_reason := nullif(trim(coalesce(p_reason, '')), '');

  update public.resources
     set metadata = coalesce(v_metadata, '{}'::jsonb)
                  || jsonb_build_object(
                       'locked_at',     v_now,
                       'locked_by',     v_uid,
                       'locked_reason', v_reason
                     ),
         updated_at = v_now
   where id = p_fund_id;

  perform public.record_system_event(
    v_group_id,
    'fundLocked',
    p_fund_id,
    null,
    jsonb_build_object(
      'locked_by',     v_uid,
      'locked_reason', v_reason
    )
  );
end;
$$;

revoke execute on function public.fund_lock(uuid, text) from public, anon;
grant  execute on function public.fund_lock(uuid, text) to authenticated;

comment on function public.fund_lock(uuid, text) is
  'Admin-only soft lock on a fund. Stamps locked_at / locked_by / locked_reason into resources.metadata and emits fundLocked. Does NOT block writers — Constitution §9 delegates lock-aware behavior to rules. Rejects relock of an already-locked fund. Mig 00202.';

create or replace function public.fund_unlock(p_fund_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_uid        uuid := auth.uid();
  v_group_id   uuid;
  v_archived   timestamptz;
  v_metadata   jsonb;
  v_locked_at  timestamptz;
  v_now        timestamptz := now();
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  select group_id, archived_at, metadata
    into v_group_id, v_archived, v_metadata
    from public.resources
   where id = p_fund_id
     and resource_type = 'fund'
   for update;

  if v_group_id is null then
    raise exception 'fund not found' using errcode = 'check_violation';
  end if;
  if v_archived is not null then
    raise exception 'fund is archived' using errcode = 'check_violation';
  end if;
  if not public.is_group_admin(v_group_id, v_uid) then
    raise exception 'caller is not a group admin' using errcode = '42501';
  end if;

  v_locked_at := nullif(v_metadata->>'locked_at','')::timestamptz;
  if v_locked_at is null then
    raise exception 'fund is not locked' using errcode = 'check_violation';
  end if;

  update public.resources
     set metadata    = ((coalesce(v_metadata, '{}'::jsonb)
                          - 'locked_at')
                          - 'locked_by')
                          - 'locked_reason',
         updated_at  = v_now
   where id = p_fund_id;

  perform public.record_system_event(
    v_group_id,
    'fundUnlocked',
    p_fund_id,
    null,
    jsonb_build_object(
      'unlocked_by',         v_uid,
      'previous_locked_at',  v_locked_at
    )
  );
end;
$$;

revoke execute on function public.fund_unlock(uuid) from public, anon;
grant  execute on function public.fund_unlock(uuid) to authenticated;

comment on function public.fund_unlock(uuid) is
  'Admin-only lock release on a fund. Clears locked_at / locked_by / locked_reason from resources.metadata and emits fundUnlocked. Rejects if fund is not locked. Mig 00202.';
