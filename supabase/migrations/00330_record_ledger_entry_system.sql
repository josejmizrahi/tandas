-- 00330 — `record_ledger_entry_system` RPC: service-role variant of
-- record_ledger_entry for cron/trigger emit paths.
--
-- Why
-- ===
-- Plans/Active/CleanupAudit_2026-05-18/06_edge_functions.md §4 #2: the
-- finalize-fine-reviews cron does .from("ledger_entries").insert({...})
-- directly, bypassing the validation that record_ledger_entry performs
-- (type allowlist, amount non-negative, resource belongs to group,
-- members are active in group). The reason the cron CAN'T just call
-- record_ledger_entry: that RPC requires auth.uid() and an `is_group_member`
-- check, which fails for service-role callers.
--
-- This migration introduces a service-role sibling that:
--   - skips the auth.uid() + is_group_member check (cron is system-trusted)
--   - keeps the type-allowlist, amount, resource-group, and member-group
--     guards (those are integrity invariants, not authorization)
--   - records recorded_by = NULL (no user attribution; payload metadata
--     should name the cron via `via` for audit clarity)
--
-- Idempotency: same as the user-facing record_ledger_entry — no UNIQUE on
-- (resource_id, type, metadata->>fine_id) at the table level today. The
-- finalize-fine-reviews cron uses its review-period set-once gate to
-- prevent re-emission; other callers using this RPC must do their own
-- dedup before invoking.
--
-- Sweep follow-up
-- ===============
-- Other system-side direct inserts into ledger_entries (mig 00148, 00150,
-- 00155, 00163, 00196 — triggers and SECURITY DEFINER RPCs) are NOT
-- migrated by this commit. Those live inside plpgsql functions where the
-- direct INSERT is idiomatic; routing them through this RPC would add a
-- function-call layer with no validation gain. Migration to this helper
-- is reserved for edge-function callers where the auth-check mismatch is
-- the structural problem.
--
-- Service-role only. Returns the inserted row (matches the user-facing
-- RPC's return shape for symmetry).
--
-- Rollback
-- ========
-- _rollbacks/00330_rollback.sql

create or replace function public.record_ledger_entry_system(
  p_group_id       uuid,
  p_resource_id    uuid,
  p_type           text,
  p_amount_cents   bigint,
  p_from_member_id uuid    default null,
  p_to_member_id   uuid    default null,
  p_currency       text    default 'MXN',
  p_metadata       jsonb   default '{}'::jsonb,
  p_occurred_at    timestamptz default null
) returns public.ledger_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.ledger_entries;
  v_allowed_types constant text[] := array[
    'expense', 'contribution', 'payout', 'settlement', 'reimbursement',
    'payment', 'transfer',
    'fine_issued', 'fine_paid', 'fine_voided', 'fine_officialized'
  ];
  v_at timestamptz := coalesce(p_occurred_at, now());
begin
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'record_ledger_entry_system: amount must be non-negative (got %)', p_amount_cents;
  end if;
  if p_type is null or not (p_type = any (v_allowed_types)) then
    raise exception 'record_ledger_entry_system: invalid ledger entry type: %', p_type;
  end if;
  if p_resource_id is not null then
    if not exists (
      select 1 from public.resources r where r.id = p_resource_id and r.group_id = p_group_id
    ) then
      raise exception 'record_ledger_entry_system: resource % does not belong to group %', p_resource_id, p_group_id;
    end if;
  end if;
  if p_from_member_id is not null then
    if not exists (
      select 1 from public.group_members gm
       where gm.id = p_from_member_id and gm.group_id = p_group_id and gm.active
    ) then
      raise exception 'record_ledger_entry_system: from_member % is not an active member of group %', p_from_member_id, p_group_id;
    end if;
  end if;
  if p_to_member_id is not null then
    if not exists (
      select 1 from public.group_members gm
       where gm.id = p_to_member_id and gm.group_id = p_group_id and gm.active
    ) then
      raise exception 'record_ledger_entry_system: to_member % is not an active member of group %', p_to_member_id, p_group_id;
    end if;
  end if;

  insert into public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
  )
  values (
    p_group_id, p_resource_id, p_type, p_amount_cents, coalesce(p_currency, 'MXN'),
    p_from_member_id, p_to_member_id, coalesce(p_metadata, '{}'::jsonb),
    v_at, now(), null
  )
  returning * into v_entry;

  return v_entry;
end;
$$;

revoke execute on function public.record_ledger_entry_system(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, timestamptz) from public, anon, authenticated;
grant  execute on function public.record_ledger_entry_system(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, timestamptz) to service_role;

comment on function public.record_ledger_entry_system(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, timestamptz) is
  'Service-role variant of record_ledger_entry for cron/edge-fn emit paths. Same integrity validation (type allowlist, amount non-negative, resource-belongs-to-group, members-active-in-group) but skips the auth.uid + is_group_member check that blocks system callers. recorded_by = NULL. Mig 00330. CleanupAudit_2026-05-18 §06.4.2.';
