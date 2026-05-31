-- 00363 — SharedMoney wrapper RPCs (Phase 2, brick 1).
--
-- Why
-- ===
-- After Phase 1, iOS still has to know a fund's UUID to spend money:
--
--   app.fundRepo.recordExpense(fundId: someFundId, …)
--
-- That's wrong shape per founder doctrine § 10/§11: from the user's
-- mental model, "I'm spending money for this group" is the primitive,
-- and the underlying pool is an implementation detail. The wrapper
-- RPCs introduced here take group_id as the entry point and resolve
-- the canonical shared pool internally.
--
-- New RPCs
-- ========
--   * record_shared_expense(p_group_id, …) — public/authenticated
--     entry point for the founder's § 11 expense flow. Resolves the
--     group's shared pool, delegates to fund_record_expense.
--
--   * contribute_to_shared_money(p_group_id, …) — symmetric entry
--     for adding money to the pool. Delegates to fund_contribute.
--
-- Both:
--   * Resolve `shared_pool_id` via the canonical lookup
--     `(group_id, resource_type='fund', metadata.is_shared_pool='true',
--      archived_at IS NULL)`. Mig 00357 + 00359 guarantee exactly
--     one such row per active group.
--   * Pre-check group membership for cleaner errors (the underlying
--     RPC also enforces, but the wrapper's error message is shaped
--     for the new shape).
--   * Pass-through `p_source_resource_id`, `p_client_id`,
--     `p_paid_by_member_id` (record_shared_expense only) to the
--     underlying RPC.
--   * Do NOT add new validation logic — single source of truth lives
--     in fund_contribute / fund_record_expense.
--
-- Compat posture
-- ==============
-- The legacy `fund_contribute` / `fund_record_expense` RPCs STAY
-- live and untouched. They're still the entry point for:
--   * Protected funds (Phase 6 surface — once Phase 6 lands, that UI
--     calls them directly with a specific fund_id).
--   * Legacy fund rows on existing groups (the 6 in dev — users may
--     still interact with them until Phase 3 deprecates the UI).
--   * Any iOS client that hasn't been updated to the new wrappers.
--
-- iOS migration (separate PR, Phase 2 follow-up):
--   * `LiveFundRepository` adds two new methods that hit the wrappers.
--   * `RecordExpenseFromFundSheet` / `ContributeToFundSheet` switch to
--     the new methods when the fund row is `is_shared_pool=true`.
--     Protected/legacy paths keep using the fund_*_RPC by fund_id.
--
-- Permission posture
-- ==================
-- Doctrine `registrar ≠ aprobar` holds: any active group member can
-- record. The wrappers preserve this by pre-checking `is_group_member`
-- only — no permission slug, no admin gate. The underlying RPCs do
-- the same check redundantly (defense in depth).
--
-- Rollback
-- ========
-- _rollbacks/20260521170000_rollback.sql drops both wrappers.
-- Underlying writers untouched.

-- ---------------------------------------------------------------------
-- 1. record_shared_expense — group-scoped expense entry point.
-- ---------------------------------------------------------------------
-- Params mirror fund_record_expense's user-facing surface MINUS
-- p_fund_id (resolved) and MINUS p_source_event_id (legacy alias —
-- new callers should use p_source_resource_id directly).

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
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid             uuid := auth.uid();
  v_shared_pool_id  uuid;
  v_entry           public.ledger_entries;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if p_group_id is null then
    raise exception 'record_shared_expense: p_group_id required'
      using errcode = '22023';
  end if;
  if not public.is_group_member(p_group_id, v_uid) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  -- Resolve the canonical shared pool. Mig 00357 + 00359 invariant:
  -- exactly one such row per active group. The partial unique index
  -- (mig 00357 resources_one_shared_pool_per_group) makes this lookup
  -- O(1) on the index.
  select id into v_shared_pool_id
    from public.resources
   where group_id = p_group_id
     and resource_type = 'fund'
     and (metadata->>'is_shared_pool') = 'true'
     and archived_at is null
   limit 1;

  if v_shared_pool_id is null then
    -- Defensive: should never happen post-mig 00357/00359. If it
    -- does, the group is in an invalid state — surface explicitly.
    raise exception 'group has no shared pool — data invariant violated'
      using errcode = 'check_violation';
  end if;

  -- Delegate. The underlying RPC does its own validation +
  -- idempotency + ledger insert + source_resource_id stamping.
  v_entry := public.fund_record_expense(
    p_fund_id            => v_shared_pool_id,
    p_amount_cents       => p_amount_cents,
    p_to_member_id       => p_to_member_id,
    p_currency           => p_currency,
    p_note               => p_note,
    p_source_event_id    => null,  -- new shape skips legacy alias
    p_client_id          => p_client_id,
    p_paid_by_member_id  => p_paid_by_member_id,
    p_source_resource_id => p_source_resource_id
  );

  return v_entry;
end;
$$;

comment on function public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid) is
  'SharedMoney Phase 2 (mig 00363): group-scoped expense entry point. Caller supplies p_group_id; wrapper resolves the canonical shared pool and delegates to fund_record_expense. iOS no longer needs to track fund_id for shared-money flows. Protected/legacy funds still use fund_record_expense directly.';

revoke execute on function public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid) from public, anon;
grant  execute on function public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. contribute_to_shared_money — group-scoped contribution entry.
-- ---------------------------------------------------------------------

create or replace function public.contribute_to_shared_money(
  p_group_id           uuid,
  p_amount_cents       bigint,
  p_currency           text default null,
  p_note               text default null,
  p_source_resource_id uuid default null,
  p_client_id          uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid             uuid := auth.uid();
  v_shared_pool_id  uuid;
  v_entry           public.ledger_entries;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if p_group_id is null then
    raise exception 'contribute_to_shared_money: p_group_id required'
      using errcode = '22023';
  end if;
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
    raise exception 'group has no shared pool — data invariant violated'
      using errcode = 'check_violation';
  end if;

  v_entry := public.fund_contribute(
    p_fund_id            => v_shared_pool_id,
    p_amount_cents       => p_amount_cents,
    p_currency           => p_currency,
    p_note               => p_note,
    p_source_event_id    => null,
    p_client_id          => p_client_id,
    p_source_resource_id => p_source_resource_id
  );

  return v_entry;
end;
$$;

comment on function public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid) is
  'SharedMoney Phase 2 (mig 00363): group-scoped contribution entry point. Caller supplies p_group_id; wrapper resolves the canonical shared pool and delegates to fund_contribute. iOS no longer needs to track fund_id for shared-money flows.';

revoke execute on function public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid) from public, anon;
grant  execute on function public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid) to authenticated;
