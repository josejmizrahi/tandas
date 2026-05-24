-- Rollback for 20260524185000_split_participants_on_expense.sql.
-- Drops the 10-arg fund_record_expense / 9-arg record_shared_expense
-- overloads and restores the prior shapes. Any ledger_entries.metadata
-- .participants arrays already written remain as inert annotation —
-- no projection reads them yet.

drop function if exists public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid[]);
drop function if exists public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid, uuid[]);

-- Restore the pre-mig-00367 9-arg fund_record_expense.
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
language plpgsql security definer set search_path = 'public', 'pg_catalog'
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
  if p_source_resource_id is not null then
    select group_id into v_src_group from public.resources where id = p_source_resource_id;
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
  if p_note is not null and length(trim(p_note)) > 0 then v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note)); end if;
  if p_source_event_id is not null and p_source_resource_id is null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  if p_client_id is not null then v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id); end if;
  if p_paid_by_member_id is not null then v_payload_meta := v_payload_meta || jsonb_build_object('paid_by_member_id', p_paid_by_member_id); end if;
  begin
    v_entry := public.record_ledger_entry(
      p_group_id => v_group_id, p_resource_id => p_fund_id, p_type => 'expense',
      p_amount_cents => p_amount_cents, p_from_member_id => null, p_to_member_id => p_to_member_id,
      p_currency => v_currency, p_metadata => v_payload_meta, p_source_resource_id => v_effective_src
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

-- Restore the pre-mig-00367 8-arg record_shared_expense.
create or replace function public.record_shared_expense(
  p_group_id           uuid,
  p_amount_cents       bigint,
  p_to_member_id       uuid,
  p_currency           text default null,
  p_note               text default null,
  p_source_resource_id uuid default null,
  p_client_id          uuid default null,
  p_paid_by_member_id  uuid default null
)
returns public.ledger_entries
language plpgsql security definer set search_path = 'public', 'pg_catalog'
as $$
declare
  v_shared_pool_id uuid;
begin
  select id into v_shared_pool_id
    from public.resources
   where group_id = p_group_id
     and resource_type = 'fund'
     and (metadata->>'is_shared_pool') = 'true'
     and archived_at is null
   limit 1;
  if v_shared_pool_id is null then
    raise exception 'group has no shared pool' using errcode = 'check_violation';
  end if;
  return public.fund_record_expense(
    p_fund_id            => v_shared_pool_id,
    p_amount_cents       => p_amount_cents,
    p_to_member_id       => p_to_member_id,
    p_currency           => p_currency,
    p_note               => p_note,
    p_source_event_id    => null,
    p_client_id          => p_client_id,
    p_paid_by_member_id  => p_paid_by_member_id,
    p_source_resource_id => p_source_resource_id
  );
end;
$$;
