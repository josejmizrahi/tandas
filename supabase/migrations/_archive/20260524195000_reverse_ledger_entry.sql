-- 00368 — reverse_ledger_entry RPC + projection updates (Edit foundation).
--
-- Why
-- ===
-- The user-visible UX wants "Edit transaction" — but the ledger is an
-- append-only atom log (`LedgerRepository.swift` enforces this on the
-- client; mig 00078 + 00082 enforce it server-side). Updating past
-- entries would corrupt projections that have already been read /
-- replicated to other devices.
--
-- The scalable primitive is REVERSE: append a new entry that
-- neutralizes the original on every projection. Once we have it,
-- "Edit" composes as `reverse + new`, "Delete" composes as `reverse`,
-- and the historical record stays intact (Apple Time Machine
-- semantics — undo, never destroy).
--
-- What
-- ====
--   * `reverse_ledger_entry(p_entry_id, p_reason, p_client_id)` RPC.
--     Appends a `settlement`-type entry with `from_member_id` and
--     `to_member_id` flipped, and `metadata.reversed_ledger_entry_id`
--     pointing at the original. SECURITY DEFINER, idempotent via
--     `metadata.client_id` (mig 00351 partial unique index).
--
--   * Three projection views now exclude both reverse entries AND
--     their originals so the visible balance / aggregates return to
--     pre-operation state once the reverse is recorded:
--       - `group_money_summary_view`   (mig 00361)
--       - `resource_money_view`        (mig 00362)
--       - `member_balances_per_group`  (mig 00136)
--       - `member_balances_per_resource` (mig 00136)
--
--   * Index `ledger_entries_reversed_ledger_entry_id_idx` for the
--     `NOT EXISTS (...)` subquery the views run per row.
--
-- Permissions (V1)
-- ================
-- Only the original `recorded_by` user can reverse. Admin override
-- (`has_permission(..., 'manage_ledger')`) is deferred — easier to
-- relax later than to restrict after the fact. Reverses themselves
-- are NOT reversible (would be a meta-reversal; V2 candidate).
--
-- Backwards compat
-- ================
-- All pre-mig entries have `metadata->>'reversed_ledger_entry_id'`
-- IS NULL, so the new view predicates leave them untouched. The atom
-- emit trigger (mig 00366) keeps firing for the inserted reverse —
-- the activity feed surfaces it as a regular `ledgerEntryCreated`
-- system event; the client renders the "reversed" badge by inspecting
-- the row's `metadata.reversed_ledger_entry_id`.
--
-- Rollback
-- ========
-- Drop the function + index. The views need to revert to their pre-
-- mig forms (00361 / 00362 / 00136). Future rollback file pending.

-- ---------------------------------------------------------------------
-- 1. Index for "is this entry reversed?" lookup
-- ---------------------------------------------------------------------

create index if not exists ledger_entries_reversed_ledger_entry_id_idx
  on public.ledger_entries ((metadata->>'reversed_ledger_entry_id'))
  where metadata->>'reversed_ledger_entry_id' is not null;

-- ---------------------------------------------------------------------
-- 2. RPC: reverse_ledger_entry
-- ---------------------------------------------------------------------

create or replace function public.reverse_ledger_entry(
  p_entry_id  uuid,
  p_reason    text default null,
  p_client_id uuid default null
) returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid      uuid := auth.uid();
  v_original public.ledger_entries;
  v_existing public.ledger_entries;
  v_reverse  public.ledger_entries;
  v_meta     jsonb;
begin
  if v_uid is null then
    raise exception 'reverse_ledger_entry: auth required' using errcode = '42501';
  end if;
  if p_entry_id is null then
    raise exception 'reverse_ledger_entry: p_entry_id required' using errcode = '22023';
  end if;

  -- Idempotency: same client_id replays the prior reverse instead of
  -- emitting a duplicate (matches the mig 00351 fund_writers pattern).
  if p_client_id is not null then
    select * into v_existing
      from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text
     limit 1;
    if v_existing.id is not null then
      return v_existing;
    end if;
  end if;

  -- Load + lock the original.
  select * into v_original
    from public.ledger_entries
   where id = p_entry_id
   for update;
  if v_original.id is null then
    raise exception 'reverse_ledger_entry: entry % not found', p_entry_id
      using errcode = 'check_violation';
  end if;

  -- V1 authorization: only the original recorder can reverse.
  if v_original.recorded_by is distinct from v_uid then
    raise exception 'reverse_ledger_entry: only the original recorder can reverse this entry'
      using errcode = '42501';
  end if;

  -- Reject double-reverses (semantically a no-op + would orphan the
  -- second pointer).
  if exists (
    select 1 from public.ledger_entries r
     where (r.metadata->>'reversed_ledger_entry_id') = p_entry_id::text
  ) then
    raise exception 'reverse_ledger_entry: entry % already reversed', p_entry_id
      using errcode = '23505';
  end if;

  -- A reverse entry is not itself reversible (it represents the undo,
  -- not a primary movement). To "un-reverse", record the original
  -- payload again — that's a forward action, not a meta-rollback.
  if v_original.metadata ? 'reversed_ledger_entry_id' then
    raise exception 'reverse_ledger_entry: cannot reverse a reversal entry'
      using errcode = 'check_violation';
  end if;

  v_meta := jsonb_build_object(
    'reversed_ledger_entry_id', p_entry_id::text,
    'reversed_original_type',   v_original.type
  );
  if p_reason is not null and length(trim(p_reason)) > 0 then
    v_meta := v_meta || jsonb_build_object('reason', trim(p_reason));
  end if;
  if p_client_id is not null then
    v_meta := v_meta || jsonb_build_object('client_id', p_client_id::text);
  end if;

  -- Insert via the canonical RPC so the atom-emit trigger fires.
  -- type='settlement' is the closest semantic ("money moving back to
  -- neutralize a previous movement"). from_member_id / to_member_id
  -- are flipped — every projection that nets by from/to will cancel
  -- the original; type-filtered views (group_money_summary_view /
  -- resource_money_view) skip the reverse entirely AND skip the
  -- original via the predicate added below.
  begin
    v_reverse := public.record_ledger_entry(
      p_group_id           => v_original.group_id,
      p_resource_id        => v_original.resource_id,
      p_type               => 'settlement',
      p_amount_cents       => v_original.amount_cents,
      p_from_member_id     => v_original.to_member_id,
      p_to_member_id       => v_original.from_member_id,
      p_currency           => v_original.currency,
      p_metadata           => v_meta,
      p_source_resource_id => v_original.source_resource_id
    );
  exception when unique_violation then
    if p_client_id is not null then
      select * into v_existing
        from public.ledger_entries
       where (metadata->>'client_id') = p_client_id::text
       limit 1;
      if v_existing.id is not null then
        return v_existing;
      end if;
    end if;
    raise;
  end;

  return v_reverse;
end;
$$;

revoke execute on function public.reverse_ledger_entry(uuid, text, uuid) from public, anon;
grant  execute on function public.reverse_ledger_entry(uuid, text, uuid) to authenticated;

comment on function public.reverse_ledger_entry(uuid, text, uuid) is
  'v1 (mig 00368): appends a settlement entry with metadata.reversed_ledger_entry_id pointing at the original and from/to flipped. Neutralizes the original on every projection (member_balances_per_group, group_money_summary_view, resource_money_view, member_balances_per_resource). Idempotent via p_client_id. Caller must be the original recorded_by — admin override deferred.';

-- ---------------------------------------------------------------------
-- 3. group_money_summary_view — exclude reversed entries.
-- ---------------------------------------------------------------------

create or replace view public.group_money_summary_view as
select
  r.group_id,
  coalesce(le.currency, r.metadata->>'currency', 'MXN') as currency,
  r.id as shared_pool_id,
  coalesce(sum(le.amount_cents) filter (where le.type = 'contribution'), 0)::bigint
    as shared_pool_in_cents,
  coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)::bigint
    as shared_pool_out_cents,
  (
    coalesce(sum(le.amount_cents) filter (where le.type = 'contribution'), 0)
    - coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)
  )::bigint as shared_pool_balance_cents,
  count(le.id)::bigint as entry_count,
  max(le.occurred_at) as last_activity_at
from public.resources r
left join public.ledger_entries le
  on le.resource_id = r.id
 and le.group_id    = r.group_id
 -- mig 00368: skip reverses (rows that ARE the undo) and originals
 -- (rows that have BEEN undone). Both must be invisible so the
 -- balance returns to pre-operation state.
 and (le.metadata->>'reversed_ledger_entry_id') is null
 and not exists (
   select 1 from public.ledger_entries rev
    where (rev.metadata->>'reversed_ledger_entry_id') = le.id::text
 )
where r.resource_type = 'fund'
  and (r.metadata->>'is_shared_pool') = 'true'
  and r.archived_at is null
group by r.group_id, r.id, r.metadata, le.currency;

comment on view public.group_money_summary_view is
  'v2 (mig 00368): excludes reverse entries and originals that have been reversed so "Saldo disponible" returns to pre-operation state after a reverse. Original: SharedMoney P1 mig 00361.';

-- ---------------------------------------------------------------------
-- 4. resource_money_view — exclude reversed entries.
-- ---------------------------------------------------------------------

create or replace view public.resource_money_view as
select
  le.group_id,
  le.source_resource_id,
  le.currency,
  coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)::bigint
    as spent_cents,
  coalesce(sum(le.amount_cents) filter (where le.type = 'contribution'), 0)::bigint
    as contributed_cents,
  count(*)::bigint as entry_count,
  max(le.occurred_at) as last_activity_at,
  count(distinct (le.metadata->>'paid_by_member_id'))
    filter (where le.metadata ? 'paid_by_member_id')::bigint
    as payer_count,
  (
    array_agg(le.recorded_by order by le.occurred_at desc nulls last)
  )[1] as latest_recorded_by
from public.ledger_entries le
where le.source_resource_id is not null
  and le.type in ('expense', 'contribution')
  -- mig 00368: skip reverses AND reversed originals so the resource
  -- Money Block returns to its pre-operation totals after a reverse.
  and (le.metadata->>'reversed_ledger_entry_id') is null
  and not exists (
    select 1 from public.ledger_entries rev
     where (rev.metadata->>'reversed_ledger_entry_id') = le.id::text
  )
group by le.group_id, le.source_resource_id, le.currency;

comment on view public.resource_money_view is
  'v2 (mig 00368): excludes reverse entries and reversed originals. Original: SharedMoney P1 mig 00362.';

grant select on public.resource_money_view to authenticated;

-- ---------------------------------------------------------------------
-- 5. member_balances_per_group — exclude reversed entries.
-- ---------------------------------------------------------------------

create or replace view public.member_balances_per_group
with (security_invoker = on)
as
with sent as (
  select
    le.group_id,
    le.from_member_id      as member_id,
    le.currency,
    sum(le.amount_cents)   as sent_cents
  from public.ledger_entries le
  where le.from_member_id is not null
    -- mig 00368: same exclusion as the type-filtered views.
    and (le.metadata->>'reversed_ledger_entry_id') is null
    and not exists (
      select 1 from public.ledger_entries rev
       where (rev.metadata->>'reversed_ledger_entry_id') = le.id::text
    )
  group by le.group_id, le.from_member_id, le.currency
),
received as (
  select
    le.group_id,
    le.to_member_id        as member_id,
    le.currency,
    sum(le.amount_cents)   as received_cents
  from public.ledger_entries le
  where le.to_member_id is not null
    and (le.metadata->>'reversed_ledger_entry_id') is null
    and not exists (
      select 1 from public.ledger_entries rev
       where (rev.metadata->>'reversed_ledger_entry_id') = le.id::text
    )
  group by le.group_id, le.to_member_id, le.currency
)
select
  coalesce(s.group_id,  r.group_id)  as group_id,
  coalesce(s.member_id, r.member_id) as member_id,
  coalesce(s.currency,  r.currency)  as currency,
  coalesce(s.sent_cents,     0::bigint) as sent_cents,
  coalesce(r.received_cents, 0::bigint) as received_cents,
  coalesce(r.received_cents, 0::bigint)
    - coalesce(s.sent_cents, 0::bigint)         as net_cents
from sent s
full outer join received r
  on  s.group_id  = r.group_id
  and s.member_id = r.member_id
  and s.currency  = r.currency;

comment on view public.member_balances_per_group is
  'v2 (mig 00368): excludes reverse entries and reversed originals so "Te deben / Debes" rolls back after a reverse. Original: mig 00136.';

-- ---------------------------------------------------------------------
-- 6. member_balances_per_resource — exclude reversed entries.
-- ---------------------------------------------------------------------

create or replace view public.member_balances_per_resource
with (security_invoker = on)
as
with sent as (
  select
    le.resource_id,
    le.group_id,
    le.from_member_id      as member_id,
    le.currency,
    sum(le.amount_cents)   as sent_cents
  from public.ledger_entries le
  where le.resource_id    is not null
    and le.from_member_id is not null
    and (le.metadata->>'reversed_ledger_entry_id') is null
    and not exists (
      select 1 from public.ledger_entries rev
       where (rev.metadata->>'reversed_ledger_entry_id') = le.id::text
    )
  group by le.resource_id, le.group_id, le.from_member_id, le.currency
),
received as (
  select
    le.resource_id,
    le.group_id,
    le.to_member_id        as member_id,
    le.currency,
    sum(le.amount_cents)   as received_cents
  from public.ledger_entries le
  where le.resource_id  is not null
    and le.to_member_id is not null
    and (le.metadata->>'reversed_ledger_entry_id') is null
    and not exists (
      select 1 from public.ledger_entries rev
       where (rev.metadata->>'reversed_ledger_entry_id') = le.id::text
    )
  group by le.resource_id, le.group_id, le.to_member_id, le.currency
)
select
  coalesce(s.resource_id, r.resource_id) as resource_id,
  coalesce(s.group_id,    r.group_id)    as group_id,
  coalesce(s.member_id,   r.member_id)   as member_id,
  coalesce(s.currency,    r.currency)    as currency,
  coalesce(s.sent_cents,     0::bigint)  as sent_cents,
  coalesce(r.received_cents, 0::bigint)  as received_cents,
  coalesce(r.received_cents, 0::bigint)
    - coalesce(s.sent_cents, 0::bigint)           as net_cents
from sent s
full outer join received r
  on  s.resource_id = r.resource_id
  and s.group_id    = r.group_id
  and s.member_id   = r.member_id
  and s.currency    = r.currency;

comment on view public.member_balances_per_resource is
  'v2 (mig 00368): excludes reverse entries and reversed originals. Original: mig 00136.';
