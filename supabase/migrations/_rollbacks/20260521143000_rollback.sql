-- Rollback for 20260521143000_fund_record_expense_paid_by_member.sql.
-- Restores the 7-arg signature of fund_record_expense without
-- p_paid_by_member_id. Already-recorded entries keep their
-- metadata.paid_by_member_id annotation as inert data (no projection
-- depends on it server-side), so this is data-loss-free.

drop function if exists public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid);

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
