-- 20260525233000 — record_payout RPC.
--
-- FASE 4 Wave 4 Phase 3 Tier 2 (2026-05-25): expone `payout` como
-- acción de primera clase desde iOS. El tipo `payout` ya existe en
-- `LedgerEntry.Kind` (mig 00078) y en el allowlist de
-- `record_ledger_entry` (mig 00082) pero NUNCA fue llamado desde el
-- cliente. Esta RPC es el wrapper canónico para "pool paga a un
-- miembro" cuando NO existe un receivable previo:
--
--   * Capital return / retorno de aportación
--   * Dividendo / distribución de utilidades
--   * Pago de stipendio acordado
--   * Devolución de cuota al salir del grupo
--
-- Distinct from `reimbursement` (mig 00082 + iOS sheet):
--   reimbursement = cancela un expense que el miembro fronteó
--                   (from=member, to=NULL, math-correct para que
--                   `member_balances_per_group` lo netee)
--   payout        = capital flow del pool al miembro sin prior receivable
--                   (from=NULL, to=member — canonical pool→member outflow)
--
-- Convention
-- ==========
-- `from_member_id = NULL` (pool is the source).
-- `to_member_id = recipient`.
-- Pool view (`group_money_summary_view`) does NOT include payout en
-- `shared_pool_out_cents` — que solo cuenta `expense`. Esto es
-- intencional (per mig 00361 comment): "settlement, payout, fine_*
-- excluded — they have their own surfaces". Phase 5 obligations view
-- will track stake reduction separately.
--
-- Idempotency
-- ===========
-- `p_client_id` (mig 00351 pattern) — partial unique index on
-- `metadata.client_id` guarantees retry-safe inserts. iOS holds a
-- stable UUID in `@State` per sheet open.

create or replace function public.record_payout(
  p_group_id        uuid,
  p_to_member_id    uuid,
  p_amount_cents    bigint,
  p_currency        text default null,
  p_note            text default null,
  p_client_id       uuid default null,
  p_source_resource_id uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid       uuid := auth.uid();
  v_caller_member uuid;
  v_recipient_active boolean;
  v_currency  text;
  v_metadata  jsonb;
  v_entry     public.ledger_entries;
  v_existing  public.ledger_entries;
  v_group_currency text;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  if p_group_id is null then
    raise exception 'record_payout: group_id required' using errcode = '22023';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'record_payout: amount must be positive' using errcode = '22023';
  end if;

  if p_to_member_id is null then
    raise exception 'record_payout: to_member_id required' using errcode = '22023';
  end if;

  -- Idempotency check (cheap pre-INSERT short-circuit).
  if p_client_id is not null then
    select * into v_existing
      from public.ledger_entries
     where (metadata->>'client_id') = p_client_id::text
     limit 1;
    if v_existing.id is not null then
      return v_existing;
    end if;
  end if;

  -- Caller must be a member of the group (any member can record a
  -- payout — admin-only gating belongs in the UI / role policy layer).
  select gm.id into v_caller_member
    from public.group_members gm
   where gm.group_id = p_group_id
     and gm.user_id = v_uid
     and gm.active
   limit 1;
  if v_caller_member is null then
    raise exception 'record_payout: caller not an active member of group'
      using errcode = '42501';
  end if;

  -- Recipient must be active in the group.
  select gm.active into v_recipient_active
    from public.group_members gm
   where gm.id = p_to_member_id
     and gm.group_id = p_group_id
   limit 1;
  if v_recipient_active is null or v_recipient_active = false then
    raise exception 'record_payout: recipient not an active member of group'
      using errcode = '22023';
  end if;

  -- Resolve currency: caller > group default.
  select g.currency into v_group_currency
    from public.groups g
   where g.id = p_group_id;
  v_currency := coalesce(p_currency, v_group_currency, 'MXN');

  -- Build metadata payload.
  v_metadata := '{}'::jsonb;
  if p_note is not null and length(trim(p_note)) > 0 then
    v_metadata := v_metadata || jsonb_build_object('note', p_note);
  end if;
  if p_client_id is not null then
    v_metadata := v_metadata || jsonb_build_object('client_id', p_client_id::text);
  end if;

  insert into public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by, source_resource_id
  )
  values (
    p_group_id, null, 'payout', p_amount_cents, v_currency,
    null, p_to_member_id, v_metadata,
    now(), now(), v_uid, p_source_resource_id
  )
  returning * into v_entry;

  return v_entry;
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
$$;

revoke execute on function public.record_payout(uuid, uuid, bigint, text, text, uuid, uuid) from public, anon;
grant  execute on function public.record_payout(uuid, uuid, bigint, text, text, uuid, uuid) to authenticated;

comment on function public.record_payout(uuid, uuid, bigint, text, text, uuid, uuid) is
  'FASE 4 Wave 4 Phase 3 Tier 2 (mig 20260525233000): canonical pool→member outflow for capital returns / dividends / stipends. Writes a `payout` ledger entry with from=NULL, to=member. Distinct from `reimbursement` (which cancels a fronted expense receivable). Idempotent via p_client_id.';
