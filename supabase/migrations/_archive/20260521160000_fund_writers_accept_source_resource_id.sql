-- 00360 — Wire fund writers to source_resource_id column
-- (SharedMoney Phase 1, brick 5).
--
-- Why
-- ===
-- Mig 00356 added `ledger_entries.source_resource_id` (a first-class
-- column, FK to resources, indexed). Today nothing writes to it —
-- the existing fund writers still stamp `metadata.source_event_id`
-- only. This brick wires both writers to populate the column so the
-- Phase 1 views (mig 00361/00362) have data to project.
--
-- Compatibility strategy (founder § 5 plan)
-- ==========================================
-- We accept BOTH the legacy `p_source_event_id` AND the new
-- `p_source_resource_id` for one cycle. Behavior:
--
--   * Only p_source_event_id (old client): validate event resource type
--     (event-only), write source_resource_id column AND keep stamping
--     metadata.source_event_id for the legacy iOS reader.
--   * Only p_source_resource_id (new client): validate same-group only
--     (resource_type can be ANY context — event/asset/space/right/etc.),
--     write source_resource_id column. Do NOT stamp metadata.source_event_id.
--   * Both: must be equal (mutual exclusion) or raise. Equal values
--     behave as the new path.
--   * Neither: column stays NULL (legacy behavior preserved).
--
-- The metadata.source_event_id stamping is kept for one cycle so a
-- stale iOS client that reads it won't break. A future Phase 2
-- cleanup mig will drop it once iOS is fully on the new param.
--
-- record_ledger_entry extension
-- =============================
-- The shared inserter `record_ledger_entry` gets a new trailing param
-- `p_source_resource_id uuid default null`. Only two callers exist
-- in the DB (the two fund writers, both using named-args), so the
-- blast radius is contained. The old 8-arg overload is dropped to
-- prevent PostgREST overload limbo (mirrors mig 00352/00354 pattern).
--
-- iOS impact
-- ==========
-- Zero in this brick. iOS still passes `sourceEventId` only — the
-- legacy validation path handles it transparently and writes the
-- column as a side effect. iOS swap to `sourceResourceId` is a
-- Phase 1 cleanup PR after this lands.
--
-- Rollback
-- ========
-- _rollbacks/20260521160000_rollback.sql restores the pre-00360
-- bodies and signatures (9-arg → 8-arg on record_ledger_entry, 6-arg
-- → fund_contribute, 8-arg → fund_record_expense). Existing ledger
-- rows that populated source_resource_id keep the column value as
-- inert data — projections that depend on it (Phase 1 views) would
-- also need rolling back. Safe in isolation.

-- ---------------------------------------------------------------------
-- 1. Extend record_ledger_entry: add p_source_resource_id (9th param).
-- ---------------------------------------------------------------------
-- Direct INSERT now also writes the source_resource_id column. Other
-- callers (fines/atoms/etc.) continue passing 8 args by name — they
-- get NULL on the new column, which is semantically correct (their
-- entries aren't context-attributed to a resource).

create or replace function public.record_ledger_entry(
  p_group_id          uuid,
  p_resource_id       uuid,
  p_type              text,
  p_amount_cents      bigint,
  p_from_member_id    uuid default null,
  p_to_member_id      uuid default null,
  p_currency          text default 'MXN',
  p_metadata          jsonb default '{}'::jsonb,
  p_source_resource_id uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid       uuid := auth.uid();
  v_entry     public.ledger_entries;
begin
  if p_group_id is null then
    raise exception 'record_ledger_entry: p_group_id required' using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'record_ledger_entry: amount must be positive' using errcode = '22023';
  end if;
  if p_type is null or length(trim(p_type)) = 0 then
    raise exception 'record_ledger_entry: type required' using errcode = '22023';
  end if;

  insert into public.ledger_entries (
    group_id, resource_id, type, amount_cents, from_member_id, to_member_id,
    currency, metadata, recorded_by, source_resource_id
  ) values (
    p_group_id, p_resource_id, p_type, p_amount_cents, p_from_member_id, p_to_member_id,
    coalesce(p_currency, 'MXN'), coalesce(p_metadata, '{}'::jsonb), v_uid, p_source_resource_id
  )
  returning * into v_entry;

  return v_entry;
end;
$$;

-- Drop the prior 8-arg overload to avoid PostgREST overload limbo.
drop function if exists public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb);

revoke execute on function public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, uuid) from public, anon;
grant  execute on function public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, uuid) to authenticated;

comment on function public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, uuid) is
  'Generic ledger inserter. Mig 00360 (SharedMoney Phase 1): added p_source_resource_id (uuid, default null) — the event/asset/space the movement RELATES TO (distinct from p_resource_id, the fund the money LIVES IN).';

-- ---------------------------------------------------------------------
-- 2. fund_contribute: accept p_source_resource_id.
-- ---------------------------------------------------------------------

create or replace function public.fund_contribute(
  p_fund_id            uuid,
  p_amount_cents       bigint,
  p_currency           text default null,
  p_note               text default null,
  p_source_event_id    uuid default null,
  p_client_id          uuid default null,
  p_source_resource_id uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid             uuid := auth.uid();
  v_group_id        uuid;
  v_metadata        jsonb;
  v_archived        timestamptz;
  v_currency        text;
  v_caller_member   uuid;
  v_payload_meta    jsonb;
  v_event_group     uuid;
  v_event_type      text;
  v_src_group       uuid;
  v_effective_src   uuid;
  v_entry           public.ledger_entries;
  v_existing        public.ledger_entries;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'contribution amount must be positive' using errcode = '22023';
  end if;

  -- Mutual-exclusion check: if both legacy and new params are set,
  -- they must agree. Equal values are accepted (new client double-passing).
  if p_source_event_id is not null and p_source_resource_id is not null
     and p_source_event_id <> p_source_resource_id then
    raise exception 'fund_contribute: p_source_event_id and p_source_resource_id refer to different rows'
      using errcode = '22023';
  end if;

  -- Idempotency check #1 (optimistic).
  if p_client_id is not null then
    select * into v_existing from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text limit 1;
    if v_existing.id is not null then
      return v_existing;
    end if;
  end if;

  select group_id, metadata, archived_at
    into v_group_id, v_metadata, v_archived
    from public.resources where id = p_fund_id and resource_type = 'fund';

  if v_group_id is null then raise exception 'fund not found' using errcode = 'check_violation'; end if;
  if v_archived is not null then raise exception 'fund is archived' using errcode = 'check_violation'; end if;
  if not public.is_group_member(v_group_id, v_uid) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  -- Legacy validation: p_source_event_id must be event-typed + same group.
  if p_source_event_id is not null then
    select group_id, resource_type into v_event_group, v_event_type
      from public.resources where id = p_source_event_id;
    if v_event_group is null then raise exception 'source event not found' using errcode = 'check_violation'; end if;
    if v_event_group <> v_group_id then raise exception 'source event belongs to a different group' using errcode = 'check_violation'; end if;
    if v_event_type <> 'event' then raise exception 'source resource is not an event (got %)', v_event_type using errcode = 'check_violation'; end if;
  end if;

  -- New validation: p_source_resource_id must be same group (any type).
  if p_source_resource_id is not null then
    select group_id into v_src_group
      from public.resources where id = p_source_resource_id;
    if v_src_group is null then raise exception 'source resource not found' using errcode = 'check_violation'; end if;
    if v_src_group <> v_group_id then raise exception 'source resource belongs to a different group' using errcode = 'check_violation'; end if;
  end if;

  -- Effective source id passed to ledger column: new param wins; legacy is alias.
  v_effective_src := coalesce(p_source_resource_id, p_source_event_id);

  select id into v_caller_member from public.group_members
   where group_id = v_group_id and user_id = v_uid and active = true limit 1;

  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');

  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note));
  end if;
  -- Compat: keep stamping metadata.source_event_id for legacy clients
  -- ONLY when caller used the legacy param (and new param wasn't used).
  if p_source_event_id is not null and p_source_resource_id is null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  if p_client_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id);
  end if;

  begin
    v_entry := public.record_ledger_entry(
      p_group_id           => v_group_id,
      p_resource_id        => p_fund_id,
      p_type               => 'contribution',
      p_amount_cents       => p_amount_cents,
      p_from_member_id     => v_caller_member,
      p_to_member_id       => null,
      p_currency           => v_currency,
      p_metadata           => v_payload_meta,
      p_source_resource_id => v_effective_src
    );
  exception when unique_violation then
    if p_client_id is not null then
      select * into v_existing from public.ledger_entries
       where (metadata->>'client_id') = p_client_id::text limit 1;
      if v_existing.id is not null then return v_existing; end if;
    end if;
    raise;
  end;

  return v_entry;
end;
$$;

drop function if exists public.fund_contribute(uuid, bigint, text, text, uuid, uuid);

revoke execute on function public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid) from public, anon;
grant  execute on function public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid) to authenticated;

comment on function public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid) is
  'v3 (SharedMoney Phase 1, mig 00360): accepts both legacy p_source_event_id and new p_source_resource_id. Mutual-exclusion guard if both differ. Writes ledger_entries.source_resource_id column. Keeps stamping metadata.source_event_id for one cycle when legacy param is used (compat). New param accepts any resource_type in the same group.';

-- ---------------------------------------------------------------------
-- 3. fund_record_expense: accept p_source_resource_id.
-- ---------------------------------------------------------------------

create or replace function public.fund_record_expense(
  p_fund_id            uuid,
  p_amount_cents       bigint,
  p_to_member_id       uuid,
  p_currency           text default null,
  p_note               text default null,
  p_source_event_id    uuid default null,
  p_client_id          uuid default null,
  p_paid_by_member_id  uuid default null,
  p_source_resource_id uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid             uuid := auth.uid();
  v_group_id        uuid;
  v_metadata        jsonb;
  v_archived        timestamptz;
  v_currency        text;
  v_payload_meta    jsonb;
  v_event_group     uuid;
  v_event_type      text;
  v_payer_group     uuid;
  v_payer_active    boolean;
  v_src_group       uuid;
  v_effective_src   uuid;
  v_entry           public.ledger_entries;
  v_existing        public.ledger_entries;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '42501'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'expense amount must be positive' using errcode = '22023';
  end if;
  if p_to_member_id is null then
    raise exception 'expense recipient required' using errcode = '22023';
  end if;
  if p_source_event_id is not null and p_source_resource_id is not null
     and p_source_event_id <> p_source_resource_id then
    raise exception 'fund_record_expense: p_source_event_id and p_source_resource_id refer to different rows'
      using errcode = '22023';
  end if;

  if p_client_id is not null then
    select * into v_existing from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text limit 1;
    if v_existing.id is not null then return v_existing; end if;
  end if;

  select group_id, metadata, archived_at
    into v_group_id, v_metadata, v_archived
    from public.resources where id = p_fund_id and resource_type = 'fund';

  if v_group_id is null then raise exception 'fund not found' using errcode = 'check_violation'; end if;
  if v_archived is not null then raise exception 'fund is archived' using errcode = 'check_violation'; end if;
  if not public.is_group_member(v_group_id, v_uid) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_source_event_id is not null then
    select group_id, resource_type into v_event_group, v_event_type
      from public.resources where id = p_source_event_id;
    if v_event_group is null then raise exception 'source event not found' using errcode = 'check_violation'; end if;
    if v_event_group <> v_group_id then raise exception 'source event belongs to a different group' using errcode = 'check_violation'; end if;
    if v_event_type <> 'event' then raise exception 'source resource is not an event (got %)', v_event_type using errcode = 'check_violation'; end if;
  end if;

  if p_source_resource_id is not null then
    select group_id into v_src_group
      from public.resources where id = p_source_resource_id;
    if v_src_group is null then raise exception 'source resource not found' using errcode = 'check_violation'; end if;
    if v_src_group <> v_group_id then raise exception 'source resource belongs to a different group' using errcode = 'check_violation'; end if;
  end if;

  if p_paid_by_member_id is not null then
    select group_id, active into v_payer_group, v_payer_active
      from public.group_members where id = p_paid_by_member_id;
    if v_payer_group is null then raise exception 'paid_by member not found' using errcode = 'check_violation'; end if;
    if v_payer_group <> v_group_id then raise exception 'paid_by member belongs to a different group' using errcode = 'check_violation'; end if;
    if not v_payer_active then raise exception 'paid_by member is not active' using errcode = 'check_violation'; end if;
  end if;

  v_effective_src := coalesce(p_source_resource_id, p_source_event_id);
  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');

  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note));
  end if;
  if p_source_event_id is not null and p_source_resource_id is null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  if p_client_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id);
  end if;
  if p_paid_by_member_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('paid_by_member_id', p_paid_by_member_id);
  end if;

  begin
    v_entry := public.record_ledger_entry(
      p_group_id           => v_group_id,
      p_resource_id        => p_fund_id,
      p_type               => 'expense',
      p_amount_cents       => p_amount_cents,
      p_from_member_id     => null,
      p_to_member_id       => p_to_member_id,
      p_currency           => v_currency,
      p_metadata           => v_payload_meta,
      p_source_resource_id => v_effective_src
    );
  exception when unique_violation then
    if p_client_id is not null then
      select * into v_existing from public.ledger_entries
       where (metadata->>'client_id') = p_client_id::text limit 1;
      if v_existing.id is not null then return v_existing; end if;
    end if;
    raise;
  end;

  return v_entry;
end;
$$;

drop function if exists public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid);

revoke execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid) from public, anon;
grant  execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid) to authenticated;

comment on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid) is
  'v4 (SharedMoney Phase 1, mig 00360): accepts both legacy p_source_event_id and new p_source_resource_id. Mutual-exclusion guard. Writes ledger_entries.source_resource_id column. Keeps stamping metadata.source_event_id for one cycle when legacy param is used. paid_by_member_id (mig 00355) preserved. New source param accepts any resource_type in the same group — not event-only.';
