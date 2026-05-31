-- 00082 — record_ledger_entry RPC (Phase 3 Money capability slice 1).
--
-- Adds a SECURITY DEFINER write path for `public.ledger_entries`. Mig 00078
-- enabled RLS on the table but only allowed direct INSERT by group admins.
-- Money atoms (expense, contribution, settlement, …) need to be recorded by
-- any group member: I paid for the dinner, I contributed to the pot, I paid
-- you back. The RPC enforces:
--
--   - caller is authenticated
--   - caller is a member of the target group
--   - from/to member ids (when provided) belong to the same group
--   - amount_cents is non-negative
--   - type is in the canonical Taxonomy §2.E whitelist
--
-- The caller passes `p_resource_id` when the entry is scoped to a specific
-- resource (event, fund, asset). Null for group-level entries. This is the
-- scope contract per Plans/Active/Taxonomy_Resources_and_Capabilities.md §29:
-- more specific scope (resource_id) wins over group-level when computing
-- balances.
--
-- Future RPCs (record_settlement, record_payout, record_iou) may layer
-- additional validations (e.g. settlement requires from + to). This slice
-- keeps the surface narrow: one polymorphic recorder, type-specific
-- validation handled client-side until the rule engine integration lands.

create or replace function public.record_ledger_entry(
  p_group_id       uuid,
  p_resource_id    uuid,
  p_type           text,
  p_amount_cents   bigint,
  p_from_member_id uuid,
  p_to_member_id   uuid,
  p_currency       text default 'MXN',
  p_metadata       jsonb default '{}'::jsonb
)
returns public.ledger_entries
language plpgsql security definer set search_path = public as $$
declare
  v_entry public.ledger_entries;
  v_allowed_types constant text[] := array[
    'expense', 'contribution', 'payout',
    'settlement', 'reimbursement', 'fine_issued', 'fine_paid'
  ];
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;

  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'not a member of this group';
  end if;

  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'amount must be non-negative';
  end if;

  if p_type is null or not (p_type = any (v_allowed_types)) then
    raise exception 'invalid ledger entry type: %', p_type;
  end if;

  if p_resource_id is not null then
    if not exists (
      select 1 from public.resources r
       where r.id = p_resource_id and r.group_id = p_group_id
    ) then
      raise exception 'resource does not belong to group';
    end if;
  end if;

  if p_from_member_id is not null then
    if not exists (
      select 1 from public.group_members gm
       where gm.id = p_from_member_id and gm.group_id = p_group_id and gm.active
    ) then
      raise exception 'from_member is not an active member of this group';
    end if;
  end if;

  if p_to_member_id is not null then
    if not exists (
      select 1 from public.group_members gm
       where gm.id = p_to_member_id and gm.group_id = p_group_id and gm.active
    ) then
      raise exception 'to_member is not an active member of this group';
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
    now(), now(), auth.uid()
  )
  returning * into v_entry;

  return v_entry;
end;
$$;

revoke execute on function public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb) from public, anon;
grant  execute on function public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb) to authenticated;

comment on function public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb) is
  'Records a money atom into public.ledger_entries. Caller must be group member. When p_resource_id is set, the entry is scoped to that resource (event, fund, asset) per Taxonomy §29 scope contract. Phase 3 Money slice 1.';
