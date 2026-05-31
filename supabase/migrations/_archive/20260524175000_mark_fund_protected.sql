-- 00365 — mark_fund_protected RPC (SharedMoney Phase 6).
--
-- Per `doctrine_shared_money.md`, protected funds are the exception
-- (fideicomiso, inversión, reserva legal). They surface separately
-- from the canonical shared pool because patrimonial separation
-- actually matters for them.
--
-- This RPC lets an admin promote an existing fund row to "protected"
-- by stamping `metadata.is_protected_fund=true`. The mutual-exclusion
-- CHECK from mig 00358 prevents stamping it on the shared pool — if
-- attempted, the constraint raises.
--
-- Why an RPC instead of a direct UPDATE
-- =====================================
-- Direct UPDATE on `public.resources` would require RLS to allow the
-- caller to mutate metadata. The existing policy is conservative.
-- Wrapping in a SECURITY DEFINER RPC keeps the explicit permission
-- gate clean: admin-only, group-scoped, idempotent.
--
-- Idempotency: calling on a row that's already protected is a no-op
-- (returns the row unchanged). Calling on the shared pool raises via
-- the mutual-exclusion CHECK from mig 00358 (defensive).

create or replace function public.mark_fund_protected(
  p_fund_id uuid
)
returns public.resources
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid       uuid := auth.uid();
  v_group_id  uuid;
  v_metadata  jsonb;
  v_archived  timestamptz;
  v_row       public.resources;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if p_fund_id is null then
    raise exception 'mark_fund_protected: p_fund_id required'
      using errcode = '22023';
  end if;

  select group_id, metadata, archived_at
    into v_group_id, v_metadata, v_archived
    from public.resources
   where id = p_fund_id
     and resource_type = 'fund'
   for update;

  if v_group_id is null then
    raise exception 'fund not found' using errcode = 'check_violation';
  end if;
  if v_archived is not null then
    raise exception 'fund is archived' using errcode = 'check_violation';
  end if;

  -- Admin-only. Promoting a fund to protected status changes how it
  -- surfaces and reads — it's a structural decision, not a routine
  -- write. Per `doctrine_registrar_no_aprobar.md` this falls under
  -- "edit fund rules" (admin gate).
  if not public.is_group_admin(v_group_id, v_uid) then
    raise exception 'only admins can mark a fund as protected'
      using errcode = '42501';
  end if;

  -- Defensive: never on the shared pool. The XOR CHECK (mig 00358)
  -- would raise on the update anyway, but a clean message helps.
  if (v_metadata->>'is_shared_pool') = 'true' then
    raise exception 'cannot mark the canonical shared pool as protected'
      using errcode = 'check_violation';
  end if;

  -- Idempotent: skip the update if already protected.
  if (v_metadata->>'is_protected_fund') = 'true' then
    select * into v_row from public.resources where id = p_fund_id;
    return v_row;
  end if;

  update public.resources
     set metadata = metadata || jsonb_build_object('is_protected_fund', true),
         updated_at = now()
   where id = p_fund_id
   returning * into v_row;

  return v_row;
end;
$$;

comment on function public.mark_fund_protected(uuid) is
  'SharedMoney Phase 6 (mig 00365): admin-only, idempotent. Stamps metadata.is_protected_fund=true on a fund row. Raises on the shared pool (XOR with is_shared_pool). Per doctrine_shared_money.md, protected funds surface in the advanced "Otros fondos" / "Fondos separados" surface, not on the canonical group home.';

revoke execute on function public.mark_fund_protected(uuid) from public, anon;
grant  execute on function public.mark_fund_protected(uuid) to authenticated;
