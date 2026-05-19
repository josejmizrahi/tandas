-- 00344 — Flow 3 slice 1: fund_contribute + fund_record_expense accept
-- an optional p_source_event_id so callers from an event context can
-- mark each entry as scoped to a specific event without duplicating
-- the fund per-event (founder doctrine 2026-05-18: shared fund, scoped
-- entries — never per-event fund).
--
-- Why
-- ===
-- Today the only way to attribute a ledger entry to a specific event is
-- via free-form metadata, which nothing enforces. The event detail's
-- Money tab therefore can't render "gastos de esta cena" reliably, and
-- the activity feed can't say "Jose registró $500 en Bhuiii desde
-- Fondo bros" because there's no link back.
--
-- This migration:
--   1. DROPs the two RPCs and re-CREATEs them with an optional
--      `p_source_event_id uuid default null` trailing param.
--   2. Validates the source event exists in the SAME group and has
--      resource_type='event'.
--   3. Stamps it into the entry metadata as `source_event_id` so the
--      projection layer can filter by event without joining links.
--
-- iOS compat: PostgREST resolves by named params + uses defaults for
-- missing ones. The companion iOS update adds `sourceEventId` to the
-- repo signatures; callers that don't pass it keep the old behavior
-- because the new arg defaults to NULL.

-- ----------------------------------------------------------------------
-- 1. fund_contribute with optional p_source_event_id
-- ----------------------------------------------------------------------

drop function if exists public.fund_contribute(uuid, bigint, text, text);

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

  -- Optional event scoping: validate same group + event resource_type.
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

  -- Build metadata: {note?, source_event_id?}
  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note));
  end if;
  if p_source_event_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;

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

revoke execute on function public.fund_contribute(uuid, bigint, text, text, uuid) from public, anon;
grant  execute on function public.fund_contribute(uuid, bigint, text, text, uuid) to authenticated;

comment on function public.fund_contribute(uuid, bigint, text, text, uuid) is
  'Records a contribution to a fund. Mig 00344: added p_source_event_id (uuid, default null) — when set, the entry metadata carries source_event_id, allowing event-scoped balance projections without duplicating the fund per-event. Validates source event belongs to the same group and is resource_type=event. Currency falls through fund.metadata.currency then MXN.';

-- ----------------------------------------------------------------------
-- 2. fund_record_expense with optional p_source_event_id
-- ----------------------------------------------------------------------

drop function if exists public.fund_record_expense(uuid, bigint, uuid, text, text);

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
set search_path = public, pg_catalog
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

revoke execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid) from public, anon;
grant  execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid) to authenticated;

comment on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid) is
  'Records an expense from a fund to a recipient member. Mig 00344: added p_source_event_id (uuid, default null) — when set, the entry metadata carries source_event_id so the event detail can render its scoped spending without duplicating the fund. Validates source event belongs to the same group and is resource_type=event.';;
