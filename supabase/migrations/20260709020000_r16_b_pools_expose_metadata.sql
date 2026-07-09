-- ═══════════════════════════════════════════════════════════════════════════
-- R.16.B — Viaje ↔ bote: exponer pool_accounts.metadata en list_context_pools
-- ═══════════════════════════════════════════════════════════════════════════
-- create_pool ya persiste p_metadata (R.8.B), pero list_context_pools no lo
-- devolvía al cliente. iOS necesita metadata.source_event_id para ligar el
-- bote creado desde un evento (viaje) con su evento origen.
--
-- Copia 1:1 de la definición viva (20260610240000_r8_b_pool_rpcs_core.sql —
-- ninguna migración posterior la redefine) + una sola línea nueva:
-- 'metadata', pa.metadata.

create or replace function public.list_context_pools(p_parent_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_pools jsonb;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  if not public.is_context_member(p_parent_context_actor_id) then
    raise exception 'not a member of context %', p_parent_context_actor_id using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'pool_account_id', pa.id,
    'pool_actor_id', pa.pool_actor_id,
    'display_name', pa.display_name,
    'description', pa.description,
    'policy_key', pa.policy_key,
    'policy_config', pa.policy_config,
    'status', pa.status,
    'currency', pa.currency,
    'target_amount', pa.target_amount,
    'metadata', pa.metadata,
    'created_at', pa.created_at,
    'resolved_at', pa.resolved_at,
    'totals', jsonb_build_object(
      'basis_total', coalesce(totals.basis_total, 0),
      'my_basis', coalesce(totals.my_basis, 0),
      'contributor_count', coalesce(totals.contributor_count, 0),
      'entry_count', coalesce(totals.entry_count, 0)
    )
  ) order by
    case pa.status when 'open' then 0 when 'target_reached' then 1
                   when 'resolving' then 2 when 'resolved' then 3
                   when 'cancelled' then 4 else 5 end,
    pa.created_at desc
  ), '[]'::jsonb)
    into v_pools
    from public.pool_accounts pa
    left join lateral (
      select
        sum(pbe.basis_amount) filter (
          where pbe.currency is not distinct from pa.currency or pbe.basis_kind = 'asset'
        ) as basis_total,
        sum(pbe.basis_amount) filter (
          where (pbe.currency is not distinct from pa.currency or pbe.basis_kind = 'asset')
            and pbe.contributor_actor_id = v_caller
        ) as my_basis,
        count(distinct pbe.contributor_actor_id) as contributor_count,
        count(*) as entry_count
      from public.pool_basis_entries pbe
     where pbe.pool_account_id = pa.id
    ) totals on true
   where pa.parent_context_actor_id = p_parent_context_actor_id;

  return v_pools;
end; $$;

revoke all on function public.list_context_pools(uuid) from public, anon;
grant execute on function public.list_context_pools(uuid) to authenticated, service_role;

comment on function public.list_context_pools(uuid) is
  'R.8.B + R.16.B: pools del contexto con basis_total + my_basis + contributor_count + metadata (linkage evento↔bote vía metadata.source_event_id).';
