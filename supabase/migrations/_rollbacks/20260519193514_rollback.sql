-- Rollback for 20260519193514_fund_writers_client_id_idempotency.sql.
-- Drops the partial unique index on metadata.client_id and restores the
-- pre-V1-01 RPC overloads (without p_client_id).
-- WARNING: rolls back retry-idempotency — re-tap by iOS user will again
-- create duplicate ledger entries / double the fund balance. Emergency
-- revert only.
--
-- Note: rolling this back does NOT delete data. Existing ledger entries
-- with metadata.client_id keep their metadata. The index drop just makes
-- the dedup signal inert; future inserts may now duplicate.

drop index if exists public.ledger_entries_client_id_unique;

-- Restore fund_contribute signature without p_client_id (pre-V1-01 body
-- from mig 20260519054723_fund_writers_accept_source_event_id.sql).
create or replace function public.fund_contribute(
  p_fund_id         uuid,
  p_amount_cents    bigint,
  p_currency        text default null,
  p_note            text default null,
  p_source_event_id uuid default null
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
  where id = p_fund_id and resource_type = 'fund';
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
  select id into v_caller_member from public.group_members
   where group_id = v_group_id and user_id = v_uid and active = true limit 1;
  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');
  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note));
  end if;
  if p_source_event_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  v_entry := public.record_ledger_entry(
    p_group_id => v_group_id, p_resource_id => p_fund_id, p_type => 'contribution',
    p_amount_cents => p_amount_cents, p_from_member_id => v_caller_member, p_to_member_id => null,
    p_currency => v_currency, p_metadata => v_payload_meta
  );
  return v_entry;
end;
$$;

create or replace function public.fund_record_expense(
  p_fund_id         uuid,
  p_amount_cents    bigint,
  p_to_member_id    uuid,
  p_currency        text default null,
  p_note            text default null,
  p_source_event_id uuid default null
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
begin
  if v_uid is null then raise exception 'auth required' using errcode = '42501'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'expense amount must be positive' using errcode = '22023';
  end if;
  if p_to_member_id is null then raise exception 'expense recipient required' using errcode = '22023'; end if;
  select group_id, metadata, archived_at into v_group_id, v_metadata, v_archived
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
  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');
  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note));
  end if;
  if p_source_event_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  v_entry := public.record_ledger_entry(
    p_group_id => v_group_id, p_resource_id => p_fund_id, p_type => 'expense',
    p_amount_cents => p_amount_cents, p_from_member_id => null, p_to_member_id => p_to_member_id,
    p_currency => v_currency, p_metadata => v_payload_meta
  );
  return v_entry;
end;
$$;
