-- 00364 — in_kind contribution flag on fund_contribute + contribute_to_shared_money.
-- SharedMoney Phase 4.5: distinguishes cash aportes from non-cash
-- (land, equipment, donated valuables) per
-- `doctrine_in_kind_contributions.md`. Backend stamps
-- `metadata.in_kind=true` when set so future surfaces can break the
-- breakdown into cash vs in-kind without re-reading every entry.
--
-- Today no projection or RPC filters on `in_kind` — it's a passive
-- annotation. UI (Phase 4.5 brick C) writes it via the contribute
-- sheet's toggle.
--
-- Compat: backwards-compat via default false. Old clients keep
-- working — their entries land with no in_kind key (treated as cash).

create or replace function public.fund_contribute(
  p_fund_id            uuid,
  p_amount_cents       bigint,
  p_currency           text default null,
  p_note               text default null,
  p_source_event_id    uuid default null,
  p_client_id          uuid default null,
  p_source_resource_id uuid default null,
  p_in_kind            boolean default false
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
  v_caller_member   uuid;
  v_payload_meta    jsonb;
  v_event_group     uuid;
  v_event_type      text;
  v_src_group       uuid;
  v_effective_src   uuid;
  v_entry           public.ledger_entries;
  v_existing        public.ledger_entries;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '42501'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'contribution amount must be positive' using errcode = '22023'; end if;
  if p_source_event_id is not null and p_source_resource_id is not null
     and p_source_event_id <> p_source_resource_id then
    raise exception 'fund_contribute: p_source_event_id and p_source_resource_id refer to different rows'
      using errcode = '22023';
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
  if not public.is_group_member(v_group_id, v_uid) then raise exception 'not a member of this group' using errcode = '42501'; end if;
  if p_source_event_id is not null then
    select group_id, resource_type into v_event_group, v_event_type
      from public.resources where id = p_source_event_id;
    if v_event_group is null then raise exception 'source event not found' using errcode = 'check_violation'; end if;
    if v_event_group <> v_group_id then raise exception 'source event belongs to a different group' using errcode = 'check_violation'; end if;
    if v_event_type <> 'event' then raise exception 'source resource is not an event (got %)', v_event_type using errcode = 'check_violation'; end if;
  end if;
  if p_source_resource_id is not null then
    select group_id into v_src_group from public.resources where id = p_source_resource_id;
    if v_src_group is null then raise exception 'source resource not found' using errcode = 'check_violation'; end if;
    if v_src_group <> v_group_id then raise exception 'source resource belongs to a different group' using errcode = 'check_violation'; end if;
  end if;
  v_effective_src := coalesce(p_source_resource_id, p_source_event_id);
  select id into v_caller_member from public.group_members
   where group_id = v_group_id and user_id = v_uid and active = true limit 1;
  v_currency := coalesce(p_currency, v_metadata->>'currency', 'MXN');
  v_payload_meta := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then v_payload_meta := v_payload_meta || jsonb_build_object('note', trim(p_note)); end if;
  if p_source_event_id is not null and p_source_resource_id is null then
    v_payload_meta := v_payload_meta || jsonb_build_object('source_event_id', p_source_event_id);
  end if;
  if p_client_id is not null then v_payload_meta := v_payload_meta || jsonb_build_object('client_id', p_client_id); end if;
  if p_in_kind then v_payload_meta := v_payload_meta || jsonb_build_object('in_kind', true); end if;
  begin
    v_entry := public.record_ledger_entry(
      p_group_id => v_group_id, p_resource_id => p_fund_id, p_type => 'contribution',
      p_amount_cents => p_amount_cents, p_from_member_id => v_caller_member, p_to_member_id => null,
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

drop function if exists public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid);
revoke execute on function public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid, boolean) from public, anon;
grant  execute on function public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid, boolean) to authenticated;
comment on function public.fund_contribute(uuid, bigint, text, text, uuid, uuid, uuid, boolean) is
  'v4 (SharedMoney Phase 4.5, mig 00364): adds p_in_kind boolean default false. When true stamps metadata.in_kind=true so capital-in-kind contributions (terreno, equipo) are distinguishable from cash. No projection filters on it today — passive annotation for future per-member surfaces.';

-- ---------------------------------------------------------------------
-- Wrapper passes p_in_kind through.
-- ---------------------------------------------------------------------

create or replace function public.contribute_to_shared_money(
  p_group_id           uuid,
  p_amount_cents       bigint,
  p_currency           text default null,
  p_note               text default null,
  p_source_resource_id uuid default null,
  p_client_id          uuid default null,
  p_in_kind            boolean default false
)
returns public.ledger_entries
language plpgsql security definer set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid             uuid := auth.uid();
  v_shared_pool_id  uuid;
  v_entry           public.ledger_entries;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '42501'; end if;
  if p_group_id is null then raise exception 'contribute_to_shared_money: p_group_id required' using errcode = '22023'; end if;
  if not public.is_group_member(p_group_id, v_uid) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  select id into v_shared_pool_id
    from public.resources
   where group_id = p_group_id
     and resource_type = 'fund'
     and (metadata->>'is_shared_pool') = 'true'
     and archived_at is null
   limit 1;

  if v_shared_pool_id is null then
    raise exception 'group has no shared pool — data invariant violated' using errcode = 'check_violation';
  end if;

  v_entry := public.fund_contribute(
    p_fund_id            => v_shared_pool_id,
    p_amount_cents       => p_amount_cents,
    p_currency           => p_currency,
    p_note               => p_note,
    p_source_event_id    => null,
    p_client_id          => p_client_id,
    p_source_resource_id => p_source_resource_id,
    p_in_kind            => p_in_kind
  );

  return v_entry;
end;
$$;

drop function if exists public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid);
revoke execute on function public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid, boolean) from public, anon;
grant  execute on function public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid, boolean) to authenticated;
comment on function public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid, boolean) is
  'v2 (SharedMoney Phase 4.5, mig 00364): adds p_in_kind boolean pass-through to fund_contribute.';
