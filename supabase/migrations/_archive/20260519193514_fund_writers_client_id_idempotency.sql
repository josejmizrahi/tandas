-- 00351 — fund_contribute + fund_record_expense retry-idempotent via p_client_id.
--
-- Bug (V1-01, FASE 0 correctness sprint)
-- ======================================
-- Neither fund_contribute nor fund_record_expense has an idempotency key.
-- iOS coordinator has no automatic retry — the user's retry mechanism is
-- to re-tap "Aportar" / "Registrar gasto" after seeing a network error.
-- Each re-tap fires a fresh RPC, which calls record_ledger_entry, which
-- INSERTs another row into ledger_entries. fund_balance projections add
-- both rows → user paid once, the fund credits twice.
--
-- Founder doctrine: "Un retry que duplique dinero ... destruye confianza
-- sistémica."
--
-- pay_fine already has its own ad-hoc dedup (EXISTS on metadata.fine_id);
-- V1-01 introduces a CLEAN generic idempotency pattern via client-supplied
-- UUIDs, which the iOS layer can persist in SwiftUI @State to make
-- re-taps safe.
--
-- Design
-- ======
-- * Add `p_client_id uuid default null` to both RPCs (backwards-compat:
--   pre-V1-01 callers keep working without idempotency).
-- * iOS generates a UUID when the contribution/expense sheet opens,
--   stores it in @State, reuses it on submit. Re-taps after error reuse
--   the same UUID; sheet dismiss → re-open generates a new one.
-- * Inside the RPC: if p_client_id is given, EXISTS-check
--   ledger_entries.metadata->>'client_id' first. If found, return the
--   prior row. Otherwise INSERT with client_id baked into metadata.
-- * Partial unique index on ledger_entries((metadata->>'client_id'))
--   WHERE not null. UUIDs are 122-bit random → globally unique by
--   construction; a global (non-(resource_id, client_id) composite)
--   index is strictly stricter (catches any iOS misuse that would
--   reuse a UUID across funds) and uses a smaller key.
-- * unique_violation catch on INSERT handles the race between EXISTS
--   and INSERT — re-fetches the row inserted by the parallel caller.
-- * record_ledger_entry helper stays unchanged. Dedup belongs in the
--   entry-point RPC, not the generic insert helper (other types like
--   fine_paid have their own dedup semantics).
--
-- Behavior
-- ========
--   1st call,   p_client_id=A → INSERT new row R1.
--   2nd call,   p_client_id=A → return R1 (no new row).
--   1st call,   p_client_id=B → INSERT new row R2.
--   1st call,   p_client_id=null → INSERT new row each time (legacy path).
--
-- Idempotent CREATE OR REPLACE + CREATE INDEX IF NOT EXISTS.
--
-- Rollback
-- ========
-- _rollbacks/20260519193514_rollback.sql drops the index and restores the
-- pre-V1-01 RPC overloads (without p_client_id). Safe revert; data in
-- ledger_entries.metadata->>'client_id' becomes inert dead-weight but
-- doesn't break anything.

-- Step 1: partial unique index for client_id dedup.
create unique index if not exists ledger_entries_client_id_unique
  on public.ledger_entries ((metadata->>'client_id'))
  where (metadata->>'client_id') is not null;

comment on index public.ledger_entries_client_id_unique is
  'V1-01 (mig 00351): partial unique index on metadata.client_id for retry-idempotency in fund_contribute / fund_record_expense. UUIDs are globally unique by construction.';

-- Step 2: fund_contribute with p_client_id.
create or replace function public.fund_contribute(
  p_fund_id         uuid,
  p_amount_cents    bigint,
  p_currency        text default null,
  p_note            text default null,
  p_source_event_id uuid default null,
  p_client_id       uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid            uuid := auth.uid();
  v_group_id       uuid;
  v_metadata       jsonb;
  v_archived       timestamptz;
  v_currency       text;
  v_caller_member  uuid;
  v_payload_meta   jsonb;
  v_event_group    uuid;
  v_event_type     text;
  v_entry          public.ledger_entries;
  v_existing       public.ledger_entries;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'contribution amount must be positive' using errcode = '22023';
  end if;

  -- V1-01 idempotency check #1 (optimistic): if a row already exists with
  -- this client_id, return it. Cheap pre-INSERT short-circuit.
  if p_client_id is not null then
    select * into v_existing
      from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text
     limit 1;
    if v_existing.id is not null then
      return v_existing;
    end if;
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

  if p_source_event_id is not null then
    select group_id, resource_type
      into v_event_group, v_event_type
      from public.resources
     where id = p_source_event_id;

    if v_event_group is null then
      raise exception 'source event not found' using errcode = 'check_violation';
    end if;
    if v_event_group <> v_group_id then
      raise exception 'source event belongs to a different group' using errcode = 'check_violation';
    end if;
    if v_event_type <> 'event' then
      raise exception 'source resource is not an event (got %)', v_event_type using errcode = 'check_violation';
    end if;
  end if;

  select id into v_caller_member
    from public.group_members
   where group_id = v_group_id
     and user_id  = v_uid
     and active   = true
   limit 1;

  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');

  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note));
  end if;
  if p_source_event_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  if p_client_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id);
  end if;

  -- V1-01 idempotency check #2 (race-safe): if a parallel caller inserted
  -- between our EXISTS and our INSERT, the unique index will fire — catch
  -- and return the parallel caller's row.
  begin
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

  return v_entry;
end;
$$;

-- Step 3: fund_record_expense with p_client_id.
create or replace function public.fund_record_expense(
  p_fund_id         uuid,
  p_amount_cents    bigint,
  p_to_member_id    uuid,
  p_currency        text default null,
  p_note            text default null,
  p_source_event_id uuid default null,
  p_client_id       uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid            uuid := auth.uid();
  v_group_id       uuid;
  v_metadata       jsonb;
  v_archived       timestamptz;
  v_currency       text;
  v_payload_meta   jsonb;
  v_event_group    uuid;
  v_event_type     text;
  v_entry          public.ledger_entries;
  v_existing       public.ledger_entries;
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

  if p_client_id is not null then
    select * into v_existing
      from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text
     limit 1;
    if v_existing.id is not null then
      return v_existing;
    end if;
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

  if p_source_event_id is not null then
    select group_id, resource_type
      into v_event_group, v_event_type
      from public.resources
     where id = p_source_event_id;

    if v_event_group is null then
      raise exception 'source event not found' using errcode = 'check_violation';
    end if;
    if v_event_group <> v_group_id then
      raise exception 'source event belongs to a different group' using errcode = 'check_violation';
    end if;
    if v_event_type <> 'event' then
      raise exception 'source resource is not an event (got %)', v_event_type using errcode = 'check_violation';
    end if;
  end if;

  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');

  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note));
  end if;
  if p_source_event_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  if p_client_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id);
  end if;

  begin
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

  return v_entry;
end;
$$;

comment on function public.fund_contribute(uuid, bigint, text, text, uuid, uuid) is
  'v2 (V1-01, mig 00351): retry-idempotent via p_client_id (default null, backwards-compat). Reuses existing ledger row when client_id seen before; partial unique index on ledger_entries.metadata.client_id catches the EXISTS↔INSERT race.';

comment on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid) is
  'v2 (V1-01, mig 00351): retry-idempotent via p_client_id (default null, backwards-compat). Same pattern as fund_contribute.';
