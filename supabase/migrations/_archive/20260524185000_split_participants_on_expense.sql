-- 00367 — Multi-person split participants on expense entries (P4 V1).
--
-- Per founder § 12 of the SharedMoney doctrine: V1 surfaces split
-- expense intent without graph minimization or auto-settlement
-- routing. The "split" semantically means "this expense was meant
-- to be shared among these people" — each non-payer participant
-- implicitly owes the payer `(amount / N)`.
--
-- This mig adds an optional `p_participants uuid[]` to both writers
-- (`fund_record_expense` + `record_shared_expense`). When supplied,
-- the array is stamped into `metadata.participants`. The legacy
-- single-recipient model (`p_to_member_id`) keeps working —
-- participants is an additive enrichment, not a replacement.
--
-- Auto-obligation generation (V2 candidate): a future mig could read
-- the participants array and emit N-1 settlement-shaped derivations
-- so `member_balances_per_group` reflects the split natively. V1
-- defers that — UI computes per-share client-side for now, and the
-- user manually triggers settle-ups via the existing flow.

create or replace function public.fund_record_expense(
  p_fund_id            uuid,
  p_amount_cents       bigint,
  p_to_member_id       uuid,
  p_currency           text default null,
  p_note               text default null,
  p_source_event_id    uuid default null,
  p_client_id          uuid default null,
  p_paid_by_member_id  uuid default null,
  p_source_resource_id uuid default null,
  p_participants       uuid[] default null
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
  if p_source_event_id is not null and p_source_resource_id is not null
     and p_source_event_id <> p_source_resource_id then
    raise exception 'fund_record_expense: p_source_event_id and p_source_resource_id refer to different rows' using errcode = '22023';
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
  -- P4: stamp participants when provided. Empty/null skips the key so
  -- legacy single-recipient entries stay clean.
  if p_participants is not null and array_length(p_participants, 1) > 0 then
    v_payload_meta := v_payload_meta || jsonb_build_object('participants', to_jsonb(p_participants));
  end if;

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

drop function if exists public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid);
revoke execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid, uuid[]) from public, anon;
grant  execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid, uuid[]) to authenticated;
comment on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid, uuid[]) is
  'v5 (P4 split V1, mig 00367): accepts p_participants uuid[] — stamps metadata.participants so iOS can compute per-share = amount/N client-side. Auto-obligation generation deferred to V2.';

-- ---------------------------------------------------------------------
-- Wrapper passes p_participants through.
-- ---------------------------------------------------------------------

create or replace function public.record_shared_expense(
  p_group_id           uuid,
  p_amount_cents       bigint,
  p_to_member_id       uuid,
  p_currency           text default null,
  p_note               text default null,
  p_source_resource_id uuid default null,
  p_client_id          uuid default null,
  p_paid_by_member_id  uuid default null,
  p_participants       uuid[] default null
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
  if p_group_id is null then raise exception 'record_shared_expense: p_group_id required' using errcode = '22023'; end if;
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

  v_entry := public.fund_record_expense(
    p_fund_id            => v_shared_pool_id,
    p_amount_cents       => p_amount_cents,
    p_to_member_id       => p_to_member_id,
    p_currency           => p_currency,
    p_note               => p_note,
    p_source_event_id    => null,
    p_client_id          => p_client_id,
    p_paid_by_member_id  => p_paid_by_member_id,
    p_source_resource_id => p_source_resource_id,
    p_participants       => p_participants
  );

  return v_entry;
end;
$$;

drop function if exists public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid);
revoke execute on function public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid[]) from public, anon;
grant  execute on function public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid[]) to authenticated;
comment on function public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid, uuid[]) is
  'v2 (P4 split V1, mig 00367): adds p_participants pass-through to fund_record_expense.';
