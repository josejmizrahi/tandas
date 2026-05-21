-- 00355 — fund_record_expense accepts p_paid_by_member_id (en nombre de).
--
-- Why
-- ===
-- Today fund_record_expense persists exactly two member roles per entry:
--
--   * recorded_by  := auth.uid()            (the registrar in Ruul)
--   * to_member_id := p_to_member_id        (who receives the money)
--
-- That conflates two distinct real-world concepts. Founder framing
-- 2026-05-21:
--
--   "Daniel registra en Ruul que María pagó los bocadillos. El fondo le
--    reembolsa a María."
--
-- "En nombre de otro miembro" semantically means *who fronted the cash*
-- — distinct from *who gets reimbursed*. Today there is no slot for
-- that; the registrar IS implicitly assumed to be the payer.
--
-- This migration introduces p_paid_by_member_id, an optional member-id
-- annotation that lives in ledger_entries.metadata as paid_by_member_id.
--
-- Where it lives
-- ==============
-- We *intentionally* don't promote paid_by to a top-level column.
-- ledger_entries.from_member_id is reserved for the money SOURCE in
-- double-entry math; for a fund expense the source IS the fund (NULL).
-- Setting from_member_id := paid_by would invert the projection
-- (fund_balance_view would treat the entry as a contribution-shaped
-- inflow). paid_by is provenance/attribution, not a flow column —
-- metadata is the correct home and the unique-on-client_id index keeps
-- retry-idempotency intact.
--
-- Doctrine
-- ========
-- Per `registrar ≠ aprobar` (founder doctrine 2026-05-19), we do NOT
-- add a permission gate on register. Any active group member can still
-- record an expense. Permissions only gate void/edit/review/admin
-- actions (which are post-V1 surfaces today). Agents that propose
-- gating registration on a tesorero/admin role: push back.
--
-- Compat
-- ======
-- create or replace adds a new trailing arg with default null, so
-- pre-V1-02 callers keep working. To avoid the same overload-limbo
-- mig 00352 fixed for client_id, this mig drops the prior 7-arg
-- overload after creating the 8-arg one.
--
-- Rollback
-- ========
-- _rollbacks/20260521143000_rollback.sql restores the 7-arg signature
-- (without p_paid_by_member_id). Existing metadata.paid_by_member_id
-- on already-recorded entries becomes inert annotation; no data loss.

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
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'expense amount must be positive' using errcode = '22023';
  end if;

  if p_to_member_id is null then
    raise exception 'expense recipient required' using errcode = '22023';
  end if;

  -- V1-01 idempotency check #1 (optimistic).
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

  -- V1-02: validate paid_by belongs to this group and is active. We
  -- only check group + active — *not* identity-vs-caller — because the
  -- whole point of this param is to let a registrar attribute the
  -- payment to a different member. recorded_by stays auth.uid() via
  -- record_ledger_entry's default; paid_by is metadata annotation.
  if p_paid_by_member_id is not null then
    select group_id, active
      into v_payer_group, v_payer_active
      from public.group_members
     where id = p_paid_by_member_id;

    if v_payer_group is null then
      raise exception 'paid_by member not found' using errcode = 'check_violation';
    end if;
    if v_payer_group <> v_group_id then
      raise exception 'paid_by member belongs to a different group' using errcode = 'check_violation';
    end if;
    if not v_payer_active then
      raise exception 'paid_by member is not active' using errcode = 'check_violation';
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
  if p_paid_by_member_id is not null then
    v_payload_meta := v_payload_meta || jsonb_build_object('paid_by_member_id', p_paid_by_member_id);
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

-- Drop the prior 7-arg overload so PostgREST can't resolve a body with
-- the 7-key shape to the legacy function. Mirrors mig 00352's approach.
drop function if exists public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid);

revoke execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid) from public, anon;
grant  execute on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid) to authenticated;

comment on function public.fund_record_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid) is
  'v3 (V1-02, mig 00355): added p_paid_by_member_id (uuid, default null). When set, validates the member belongs to this group + is active, then stamps metadata.paid_by_member_id. Distinct from to_member_id (recipient) and recorded_by (auth.uid()). NO permission gate on register — registrar ≠ aprobar doctrine still holds.';
