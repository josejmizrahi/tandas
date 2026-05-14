-- 00143 — Tier 6 final: record_settlement RPC for one-tap "Salda ahora".
--
-- Background
-- ==========
-- `record_ledger_entry` (mig 00082) is the polymorphic recorder that
-- accepts any of the 7 atom types — from/to are optional, scope is
-- optional. It works for expense (from=alice, to=null), payout
-- (from=null, to=alice), and the bilateral cases too.
--
-- For "salda ahora" — the canonical one-tap settlement — we want a
-- stricter contract:
--   - BOTH from + to required (settlements are bilateral by definition)
--   - amount > 0 (zero settlements are a no-op + UI bug indicator)
--   - both members must be active in the group
--   - caller must be a group member (anyone records, the bilateral
--     check is the real authorization)
--
-- Putting these checks in a dedicated RPC keeps the iOS call site
-- clean (no client-side validation duplication) and lets a future
-- audit dashboard query for "settlements" specifically without
-- joining ledger_entries.type.
--
-- Balance view integration
-- ========================
-- The settlement entry lands in `ledger_entries` with type='settlement',
-- from_member_id, to_member_id, amount_cents. The existing
-- `member_balances_per_group` + `member_balances_per_resource` views
-- (mig 00136) aggregate it automatically: from_member's `sent` rises,
-- to_member's `received` rises, both nets shift accordingly. No
-- additional projection migration needed.
--
-- Resource scope optional. When provided, the settlement is scoped
-- to a specific resource (e.g. "salda lo que debes de esta cena").
-- When null, group-level (general settle-up).

create or replace function public.record_settlement(
  p_group_id       uuid,
  p_from_member_id uuid,
  p_to_member_id   uuid,
  p_amount_cents   bigint,
  p_currency       text default 'MXN',
  p_resource_id    uuid default null,
  p_note           text default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.ledger_entries;
  v_caller_id uuid := auth.uid();
begin
  if v_caller_id is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  if not public.is_group_member(p_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_from_member_id is null then
    raise exception 'from_member_id required for settlement' using errcode = '22023';
  end if;
  if p_to_member_id is null then
    raise exception 'to_member_id required for settlement' using errcode = '22023';
  end if;
  if p_from_member_id = p_to_member_id then
    raise exception 'from_member and to_member must differ' using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  -- Both members must be active in the group. A settlement to an
  -- inactive member is allowed for cleanup (someone who left still
  -- gets paid back), but we still verify they exist + belong to this
  -- group to avoid cross-group settlement smuggling.
  if not exists (
    select 1 from public.group_members gm
     where gm.id = p_from_member_id
       and gm.group_id = p_group_id
       and gm.active = true
  ) then
    raise exception 'from_member is not an active member of this group' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.group_members gm
     where gm.id = p_to_member_id
       and gm.group_id = p_group_id
  ) then
    raise exception 'to_member is not a member of this group' using errcode = '22023';
  end if;

  -- Optional resource scope must also belong to this group.
  if p_resource_id is not null then
    if not exists (
      select 1 from public.resources r
       where r.id = p_resource_id
         and r.group_id = p_group_id
    ) then
      raise exception 'resource does not belong to group' using errcode = '22023';
    end if;
  end if;

  insert into public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
  )
  values (
    p_group_id,
    p_resource_id,
    'settlement',
    p_amount_cents,
    coalesce(p_currency, 'MXN'),
    p_from_member_id,
    p_to_member_id,
    case when p_note is not null and length(trim(p_note)) > 0
         then jsonb_build_object('note', trim(p_note))
         else '{}'::jsonb
    end,
    now(),
    now(),
    v_caller_id
  )
  returning * into v_entry;

  return v_entry;
end;
$$;

revoke execute on function public.record_settlement(uuid, uuid, uuid, bigint, text, uuid, text) from public, anon;
grant  execute on function public.record_settlement(uuid, uuid, uuid, bigint, text, uuid, text) to authenticated;

comment on function public.record_settlement(uuid, uuid, uuid, bigint, text, uuid, text) is
  'Tier 6 final: bilateral settlement recorder. Inserts ledger_entries type=settlement. Requires both from + to + amount > 0; both members must belong to the group (from must be active, to may be inactive for cleanup payouts). Resource scope optional. Balance projection (mig 00136 views) reflects automatically.';
