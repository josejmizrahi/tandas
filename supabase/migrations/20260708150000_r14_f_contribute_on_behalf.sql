-- R.14.F — Aportar a un bote a nombre de otro miembro.
--
-- Founder-issue documentado en PoolDetailView.swift: "el admin/tesorero recibe
-- efectivo de un miembro y necesita registrar SU aporte" — contribute_to_pool
-- siempre usaba current_actor_id() como contribuyente, así que el efectivo
-- recibido quedaba registrado a nombre del admin.
--
-- Cambio: `p_contributor_actor_id uuid default null` (null → caller, sin
-- cambio de comportamiento). Cuando difiere del caller:
--   - gate extra: el caller necesita `money.settle` en el contexto padre
--     (la misma autoridad que confirma pagos de settlement);
--   - el contribuyente debe ser miembro active del contexto padre;
--   - `basis_kind='asset'` sigue exigiendo que quien aporta sea el dueño
--     canónico del recurso → no se permite on-behalf para assets;
--   - transaction/obligation/basis quedan a nombre del CONTRIBUYENTE;
--     `created_by_actor_id` y el actor del activity event registran al caller
--     (quién lo capturó), con `contributor_actor_id` en el payload.
--   - idempotencia por (contributor, client_id) — igual que antes, pero sobre
--     el contribuyente efectivo.
--
-- DROP explícito: agregar un parámetro via CREATE OR REPLACE crearía un
-- overload y PostgREST fallaría por ambigüedad.

drop function if exists public.contribute_to_pool(uuid, text, numeric, text, uuid, text, text, jsonb, text);

create function public.contribute_to_pool(
  p_pool_account_id uuid,
  p_basis_kind text,
  p_amount numeric,
  p_currency text default null,
  p_asset_resource_id uuid default null,
  p_valuation_method text default null,
  p_valuation_notes text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null,
  p_contributor_actor_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_contributor uuid;
  v_pool record;
  v_existing_basis uuid;
  v_basis_entry uuid;
  v_obligation uuid;
  v_transaction uuid;
  v_resource_owner uuid;
  v_meta jsonb := coalesce(p_metadata, '{}'::jsonb);
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  v_contributor := coalesce(p_contributor_actor_id, v_caller);

  -- Load pool con context padre para auth gate
  select pa.id, pa.pool_actor_id, pa.parent_context_actor_id, pa.status,
         pa.currency as pool_currency, pa.policy_key
    into v_pool
    from public.pool_accounts pa where pa.id = p_pool_account_id;
  if v_pool.id is null then
    raise exception 'pool_account not found: %', p_pool_account_id using errcode = '42704';
  end if;

  if not public.has_actor_authority(v_pool.parent_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to contribute to pool' using errcode = '42501';
  end if;

  -- R.14.F: aporte a nombre de otro — gate money.settle + membership del contribuyente.
  if v_contributor <> v_caller then
    if not public.has_actor_authority(v_pool.parent_context_actor_id, v_caller, 'money.settle') then
      raise exception 'money.settle required to contribute on behalf of another member'
        using errcode = '42501';
    end if;
    if not exists (
      select 1 from public.actor_memberships
      where context_actor_id = v_pool.parent_context_actor_id
        and member_actor_id = v_contributor
        and membership_status = 'active'
    ) then
      raise exception 'contributor % is not an active member of the pool context', v_contributor
        using errcode = '22023';
    end if;
    if p_basis_kind = 'asset' then
      raise exception 'asset contributions must be made by the owner (no on-behalf)'
        using errcode = '22023';
    end if;
    v_meta := v_meta || jsonb_build_object('recorded_by_actor_id', v_caller);
  end if;

  if v_pool.status <> 'open' then
    raise exception 'pool is not open (status=%)', v_pool.status using errcode = '22023';
  end if;

  if p_basis_kind not in ('cash','asset','service','pending_stake') then
    raise exception 'invalid basis_kind: %', p_basis_kind using errcode = '22023';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  -- Idempotency check (sobre el contribuyente efectivo)
  if p_client_id is not null then
    select id into v_existing_basis
      from public.pool_basis_entries
     where contributor_actor_id = v_contributor and client_id = p_client_id;
    if v_existing_basis is not null then
      return jsonb_build_object('basis_entry_id', v_existing_basis, 'idempotent_replay', true);
    end if;
  end if;

  -- Branch por basis_kind
  if p_basis_kind in ('cash','pending_stake') then
    if p_currency is null then
      raise exception 'currency is required for cash/pending_stake' using errcode = '22023';
    end if;

    if p_basis_kind = 'cash' then
      -- 1. money_transaction (transaction_type='contribution' ya existe en CHECK)
      insert into public.money_transactions
        (context_actor_id, from_actor_id, to_actor_id, transaction_type,
         amount, currency, metadata, created_by_actor_id)
      values
        (v_pool.parent_context_actor_id, v_contributor, v_pool.pool_actor_id, 'contribution',
         p_amount, p_currency,
         v_meta || jsonb_build_object('pool_account_id', v_pool.id, 'basis_kind', 'cash'),
         v_caller)
      returning id into v_transaction;
    end if;

    -- 2. obligation (obligation_type='contribution' + status='pending_pool')
    insert into public.obligations
      (context_actor_id, debtor_actor_id, creditor_actor_id,
       obligation_type, obligation_kind, status, amount, currency, metadata)
    values
      (v_pool.parent_context_actor_id, v_contributor, v_pool.pool_actor_id,
       'contribution', 'money', 'pending_pool', p_amount, p_currency,
       v_meta || jsonb_build_object(
         'pool_account_id', v_pool.id,
         'basis_kind', p_basis_kind,
         'money_transaction_id', v_transaction
       ))
    returning id into v_obligation;

  elsif p_basis_kind = 'asset' then
    if p_asset_resource_id is null then
      raise exception 'asset_resource_id is required for basis_kind=asset' using errcode = '22023';
    end if;
    -- Validación MVP: contribuyente debe ser canonical_owner del resource. Shared
    -- ownership / partial OWN rights llegan en R.9 (founder-signed §10 risk #4).
    select canonical_owner_actor_id into v_resource_owner
      from public.resources where id = p_asset_resource_id;
    if v_resource_owner is null then
      raise exception 'resource not found: %', p_asset_resource_id using errcode = '42704';
    end if;
    if v_resource_owner <> v_caller then
      raise exception 'only canonical owner can contribute asset to pool' using errcode = '42501';
    end if;
    -- Default valuation_method='manual' (founder-signed §10 risk #5)
    if p_valuation_method is null then
      p_valuation_method := 'manual';
    end if;
  elsif p_basis_kind = 'service' then
    null;  -- modelado pero sin enforcement adicional. UI deferred R.9.
  end if;

  -- basis_entry siempre se crea (para los 4 kinds)
  insert into public.pool_basis_entries
    (pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency,
     asset_resource_id, valuation_method, valuation_notes,
     paired_obligation_id, money_transaction_id, metadata, client_id)
  values
    (v_pool.id, v_contributor, p_basis_kind, p_amount, p_currency,
     p_asset_resource_id, p_valuation_method, p_valuation_notes,
     v_obligation, v_transaction, v_meta, p_client_id)
  returning id into v_basis_entry;

  -- Emit activity en el CONTEXTO PADRE (actor = quien capturó; payload lleva
  -- al contribuyente para render honesto en el feed).
  perform public._emit_activity(
    v_pool.parent_context_actor_id, v_caller, 'pool.contributed',
    'pool_account', v_pool.id,
    jsonb_build_object(
      'pool_account_id', v_pool.id,
      'basis_entry_id', v_basis_entry,
      'basis_kind', p_basis_kind,
      'basis_amount', p_amount,
      'currency', p_currency,
      'asset_resource_id', p_asset_resource_id,
      'obligation_id', v_obligation,
      'money_transaction_id', v_transaction,
      'contributor_actor_id', v_contributor
    ),
    p_resource_id := p_asset_resource_id,
    p_obligation_id := v_obligation
  );

  return jsonb_build_object(
    'basis_entry_id', v_basis_entry,
    'paired_obligation_id', v_obligation,
    'money_transaction_id', v_transaction,
    'contributor_actor_id', v_contributor
  );
end; $$;

revoke all on function public.contribute_to_pool(uuid, text, numeric, text, uuid, text, text, jsonb, text, uuid)
  from public, anon;
grant execute on function public.contribute_to_pool(uuid, text, numeric, text, uuid, text, text, jsonb, text, uuid)
  to authenticated, service_role;

comment on function public.contribute_to_pool(uuid, text, numeric, text, uuid, text, text, jsonb, text, uuid) is
  'R.8.B + R.14.F: aporte al pool. cash/asset/service/pending_stake. p_contributor_actor_id opcional (null → caller) para registrar aportes recibidos en efectivo a nombre de otro miembro — requiere money.settle. Cash crea money_transaction + obligation(pending_pool). Permission base: money.record.';
