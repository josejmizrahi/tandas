-- Rollback for 20260521160000_fund_writers_accept_source_resource_id.sql.
-- Restores record_ledger_entry to 8-arg shape, fund_contribute to 6-arg,
-- fund_record_expense to 8-arg. Pre-existing ledger_entries.source_resource_id
-- column values remain populated as inert data (no projection reads them
-- post-rollback). Mig 00356's column itself stays — only this brick's RPC
-- bodies revert.

drop function if exists public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid);
drop function if exists public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid);
drop function if exists public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, uuid);

-- record_ledger_entry — restore pre-00360 8-arg body. Note: pre-00360
-- version had no validation — kept minimal here for revert symmetry.
create or replace function public.record_ledger_entry(
  p_group_id          uuid,
  p_resource_id       uuid,
  p_type              text,
  p_amount_cents      bigint,
  p_from_member_id    uuid default null,
  p_to_member_id      uuid default null,
  p_currency          text default 'MXN',
  p_metadata          jsonb default '{}'::jsonb
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid   uuid := auth.uid();
  v_entry public.ledger_entries;
begin
  insert into public.ledger_entries (
    group_id, resource_id, type, amount_cents, from_member_id, to_member_id,
    currency, metadata, recorded_by
  ) values (
    p_group_id, p_resource_id, p_type, p_amount_cents, p_from_member_id, p_to_member_id,
    coalesce(p_currency, 'MXN'), coalesce(p_metadata, '{}'::jsonb), v_uid
  ) returning * into v_entry;
  return v_entry;
end;
$$;

-- fund_contribute — restore pre-00360 6-arg body.
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
  if v_uid is null then raise exception 'auth required' using errcode = '42501'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'contribution amount must be positive' using errcode = '22023';
  end if;
  if p_client_id is not null then
    select * into v_existing from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text limit 1;
    if v_existing.id is not null then return v_existing; end if;
  end if;
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
    if v_event_type <> 'event' then raise exception 'source resource is not an event' using errcode = 'check_violation'; end if;
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
  if p_client_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id);
  end if;
  begin
    v_entry := public.record_ledger_entry(
      p_group_id => v_group_id, p_resource_id => p_fund_id, p_type => 'contribution',
      p_amount_cents => p_amount_cents, p_from_member_id => v_caller_member, p_to_member_id => null,
      p_currency => v_currency, p_metadata => v_payload_meta
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

-- fund_record_expense — restore pre-00360 8-arg body (includes paid_by from mig 00355).
create or replace function public.fund_record_expense(
  p_fund_id            uuid,
  p_amount_cents       bigint,
  p_to_member_id       uuid,
  p_currency           text default null,
  p_note               text default null,
  p_source_event_id    uuid default null,
  p_client_id          uuid default null,
  p_paid_by_member_id  uuid default null
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
  v_payer_group    uuid;
  v_payer_active   boolean;
  v_entry          public.ledger_entries;
  v_existing       public.ledger_entries;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '42501'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'expense amount must be positive' using errcode = '22023'; end if;
  if p_to_member_id is null then raise exception 'expense recipient required' using errcode = '22023'; end if;
  if p_client_id is not null then
    select * into v_existing from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text limit 1;
    if v_existing.id is not null then return v_existing; end if;
  end if;
  select group_id, metadata, archived_at into v_group_id, v_metadata, v_archived
    from public.resources where id = p_fund_id and resource_type = 'fund';
  if v_group_id is null then raise exception 'fund not found' using errcode = 'check_violation'; end if;
  if v_archived is not null then raise exception 'fund is archived' using errcode = 'check_violation'; end if;
  if not public.is_group_member(v_group_id, v_uid) then raise exception 'not a member of this group' using errcode = '42501'; end if;
  if p_source_event_id is not null then
    select group_id, resource_type into v_event_group, v_event_type
      from public.resources where id = p_source_event_id;
    if v_event_group is null then raise exception 'source event not found' using errcode = 'check_violation'; end if;
    if v_event_group <> v_group_id then raise exception 'source event belongs to a different group' using errcode = 'check_violation'; end if;
    if v_event_type <> 'event' then raise exception 'source resource is not an event' using errcode = 'check_violation'; end if;
  end if;
  if p_paid_by_member_id is not null then
    select group_id, active into v_payer_group, v_payer_active
      from public.group_members where id = p_paid_by_member_id;
    if v_payer_group is null then raise exception 'paid_by member not found' using errcode = 'check_violation'; end if;
    if v_payer_group <> v_group_id then raise exception 'paid_by member belongs to a different group' using errcode = 'check_violation'; end if;
    if not v_payer_active then raise exception 'paid_by member is not active' using errcode = 'check_violation'; end if;
  end if;
  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');
  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note)); end if;
  if p_source_event_id is not null then v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id); end if;
  if p_client_id is not null then v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id); end if;
  if p_paid_by_member_id is not null then v_payload_meta := v_payload_meta || jsonb_build_object('paid_by_member_id', p_paid_by_member_id); end if;
  begin
    v_entry := public.record_ledger_entry(
      p_group_id => v_group_id, p_resource_id => p_fund_id, p_type => 'expense',
      p_amount_cents => p_amount_cents, p_from_member_id => null, p_to_member_id => p_to_member_id,
      p_currency => v_currency, p_metadata => v_payload_meta
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
