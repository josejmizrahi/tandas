-- ============================================================================
-- R.8.B — POOL PRIMITIVE · RPCs CORE
-- ============================================================================
-- 4 RPCs SECURITY DEFINER integrados a los primitivos existentes del tab Dinero:
--   · create_pool          → actor pool + pool_accounts row + activity pool.created
--   · contribute_to_pool   → basis_entry (+ obligation pending_pool + money_transaction
--                            según basis_kind) + activity pool.contributed
--   · list_context_pools   → array de pools del contexto con basis_total + my_basis
--   · pool_account_detail  → pool + basis ledger + available_actions + totals
--
-- Integración doctrinal (founder: "lo más integrado posible con lo que hay hoy en dinero"):
--   · Mismo gate de auth: has_actor_authority(context, caller, 'money.record')
--   · Mismos errcodes: 28000 (unauthenticated), 42501 (not authorized), 22023 (validation)
--   · Reusa transaction_type='contribution' (ya válido en money_transactions CHECK)
--   · Reusa obligation_type='contribution' (ya válido en obligations CHECK)
--   · Idempotencia por p_client_id (mismo patrón que record_expense)
--   · _emit_activity gateway centralizado → activity_event_catalog entries añadidas
--
-- Schema additive en R.8.B (necesario para idempotencia + auditoría):
--   · pool_accounts.client_id text + UNIQUE per (created_by_actor_id, client_id)
--   · pool_basis_entries.client_id text + UNIQUE per (contributor_actor_id, client_id)
--
-- Activity catalog: pool.created + pool.contributed (pool.resolved/cancelled/target_reached
-- llegan en R.8.C — todavía no se emiten desde este migration).
--
-- Plan canónico: Plans/Active/R8_PoolPrimitive.md (§3 RPCs · §8 R.8.B DoD).
-- Resolución (preview + resolve) en R.8.C.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Schema additive: client_id columns para idempotency
-- ────────────────────────────────────────────────────────────────────────────
alter table public.pool_accounts add column if not exists client_id text;
alter table public.pool_basis_entries add column if not exists client_id text;

create unique index if not exists idx_pool_accounts_client_id
  on public.pool_accounts (created_by_actor_id, client_id)
  where client_id is not null;

create unique index if not exists idx_pool_basis_entries_client_id
  on public.pool_basis_entries (contributor_actor_id, client_id)
  where client_id is not null;

comment on column public.pool_accounts.client_id is
  'R.8.B: idempotency token. UNIQUE per (created_by_actor_id, client_id) cuando NOT NULL.';
comment on column public.pool_basis_entries.client_id is
  'R.8.B: idempotency token. UNIQUE per (contributor_actor_id, client_id) cuando NOT NULL.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Activity catalog entries (R.8.B subset: created + contributed)
-- ────────────────────────────────────────────────────────────────────────────
-- pool.resolved / pool.cancelled / pool.target_reached llegan en R.8.C.
insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('pool.created',     'pool', 'Se creó un fondo de capital colectivo (bote / JV / kitty / etc.)',
   'pool_account', false),
  ('pool.contributed', 'pool', 'Un actor aportó al fondo (cash / asset / pending_stake / service)',
   'pool_account', false)
on conflict (event_type) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. create_pool
-- ────────────────────────────────────────────────────────────────────────────
-- Permission: money.record (mismo gate que record_expense — cualquier miembro del
-- contexto puede crear un fondo). R.7 governance puede subir la barra per-contexto.
create or replace function public.create_pool(
  p_parent_context_actor_id uuid,
  p_display_name text,
  p_policy_key text,
  p_policy_config jsonb default '{}'::jsonb,
  p_currency text default null,
  p_target_amount numeric default null,
  p_description text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_existing_pool_account uuid;
  v_existing_pool_actor uuid;
  v_pool_actor uuid;
  v_pool_account uuid;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  if not public.has_actor_authority(p_parent_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to create pool in context %', p_parent_context_actor_id
      using errcode = '42501';
  end if;
  if p_display_name is null or trim(p_display_name) = '' then
    raise exception 'display_name is required' using errcode = '22023';
  end if;
  if p_policy_key not in ('winner_takes_all','equity_target','proportional','equal_share','rotational','custom_spec') then
    raise exception 'invalid policy_key: %', p_policy_key using errcode = '22023';
  end if;
  if p_policy_key = 'equity_target' and (p_target_amount is null or p_target_amount <= 0) then
    raise exception 'equity_target requires positive target_amount' using errcode = '22023';
  end if;

  -- Idempotency check
  if p_client_id is not null then
    select id, pool_actor_id into v_existing_pool_account, v_existing_pool_actor
      from public.pool_accounts
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing_pool_account is not null then
      return jsonb_build_object(
        'pool_account_id', v_existing_pool_account,
        'pool_actor_id', v_existing_pool_actor,
        'idempotent_replay', true
      );
    end if;
  end if;

  -- 1. Crear pool actor (collective, subtype='pool')
  insert into public.actors (actor_kind, actor_subtype, display_name, created_by_actor_id, metadata)
  values ('collective', 'pool', p_display_name, v_caller,
          jsonb_build_object('parent_context_actor_id', p_parent_context_actor_id))
  returning id into v_pool_actor;

  -- 2. Crear pool_accounts row
  insert into public.pool_accounts
    (pool_actor_id, parent_context_actor_id, policy_key, policy_config,
     display_name, description, currency, target_amount, metadata,
     created_by_actor_id, client_id)
  values
    (v_pool_actor, p_parent_context_actor_id, p_policy_key, coalesce(p_policy_config, '{}'::jsonb),
     trim(p_display_name), p_description, p_currency, p_target_amount,
     coalesce(p_metadata, '{}'::jsonb), v_caller, p_client_id)
  returning id into v_pool_account;

  -- 3. Emit activity en el CONTEXTO PADRE (no en el pool actor)
  perform public._emit_activity(
    p_parent_context_actor_id, v_caller, 'pool.created',
    'pool_account', v_pool_account,
    jsonb_build_object(
      'pool_account_id', v_pool_account,
      'pool_actor_id', v_pool_actor,
      'policy_key', p_policy_key,
      'display_name', trim(p_display_name),
      'currency', p_currency,
      'target_amount', p_target_amount
    )
  );

  return jsonb_build_object(
    'pool_account_id', v_pool_account,
    'pool_actor_id', v_pool_actor
  );
end; $$;

revoke all on function public.create_pool(uuid, text, text, jsonb, text, numeric, text, jsonb, text)
  from public, anon;
grant execute on function public.create_pool(uuid, text, text, jsonb, text, numeric, text, jsonb, text)
  to authenticated, service_role;

comment on function public.create_pool(uuid, text, text, jsonb, text, numeric, text, jsonb, text) is
  'R.8.B: crea pool actor + pool_accounts row + emite pool.created. Permission: money.record.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. contribute_to_pool
-- ────────────────────────────────────────────────────────────────────────────
-- Branches por basis_kind:
--   · cash          → money_transaction + obligation(pending_pool) + basis_entry
--   · asset         → basis_entry only (contributor debe ser canonical_owner del resource)
--   · service       → basis_entry only (modelado, sin UI en MVP)
--   · pending_stake → obligation(pending_pool) + basis_entry (sin money_transaction)
--
-- pending_pool obligations: settlement batcher (R.2N) las filtra fuera por status,
-- así que NO contaminan el neteo hasta que resolve_pool las crystallize a 'open'.
create or replace function public.contribute_to_pool(
  p_pool_account_id uuid,
  p_basis_kind text,
  p_amount numeric,
  p_currency text default null,
  p_asset_resource_id uuid default null,
  p_valuation_method text default null,
  p_valuation_notes text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
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

  if v_pool.status <> 'open' then
    raise exception 'pool is not open (status=%)', v_pool.status using errcode = '22023';
  end if;

  if p_basis_kind not in ('cash','asset','service','pending_stake') then
    raise exception 'invalid basis_kind: %', p_basis_kind using errcode = '22023';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  -- Idempotency check
  if p_client_id is not null then
    select id into v_existing_basis
      from public.pool_basis_entries
     where contributor_actor_id = v_caller and client_id = p_client_id;
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
        (v_pool.parent_context_actor_id, v_caller, v_pool.pool_actor_id, 'contribution',
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
      (v_pool.parent_context_actor_id, v_caller, v_pool.pool_actor_id,
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
    (v_pool.id, v_caller, p_basis_kind, p_amount, p_currency,
     p_asset_resource_id, p_valuation_method, p_valuation_notes,
     v_obligation, v_transaction, v_meta, p_client_id)
  returning id into v_basis_entry;

  -- Emit activity en el CONTEXTO PADRE
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
      'money_transaction_id', v_transaction
    ),
    p_resource_id := p_asset_resource_id,
    p_obligation_id := v_obligation
  );

  return jsonb_build_object(
    'basis_entry_id', v_basis_entry,
    'paired_obligation_id', v_obligation,
    'money_transaction_id', v_transaction
  );
end; $$;

revoke all on function public.contribute_to_pool(uuid, text, numeric, text, uuid, text, text, jsonb, text)
  from public, anon;
grant execute on function public.contribute_to_pool(uuid, text, numeric, text, uuid, text, text, jsonb, text)
  to authenticated, service_role;

comment on function public.contribute_to_pool(uuid, text, numeric, text, uuid, text, text, jsonb, text) is
  'R.8.B: aporte al pool. cash/asset/service/pending_stake. Cash crea money_transaction + obligation(pending_pool). Permission: money.record.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. list_context_pools
-- ────────────────────────────────────────────────────────────────────────────
-- Devuelve los pools del contexto con basis_total y my_basis derivados.
-- Doctrina §1.5: NO incluye la Tesorería derivada — esa es vista iOS-side.
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
  'R.8.B: pools del contexto con basis_total + my_basis + contributor_count.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. pool_account_detail
-- ────────────────────────────────────────────────────────────────────────────
-- Devuelve pool + basis ledger (con display_name del contributor) + available_actions.
-- available_actions devuelve los 4 canónicos R.8 con enabled + reason gated por status
-- (R.7 governance escalation se cablea en R.8.F).
create or replace function public.pool_account_detail(p_pool_account_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_pool record;
  v_basis_entries jsonb;
  v_totals jsonb;
  v_actions jsonb;
  v_can_record boolean := false;
  v_can_manage boolean := false;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select pa.* into v_pool from public.pool_accounts pa where pa.id = p_pool_account_id;
  if v_pool.id is null then
    raise exception 'pool_account not found: %', p_pool_account_id using errcode = '42704';
  end if;

  if not public.is_context_member(v_pool.parent_context_actor_id) then
    -- Allow lectura si el caller es contribuyente directo (cubre invitados ad-hoc)
    if not exists (
      select 1 from public.pool_basis_entries pbe
       where pbe.pool_account_id = v_pool.id and pbe.contributor_actor_id = v_caller
    ) then
      raise exception 'not authorized to view pool' using errcode = '42501';
    end if;
  end if;

  v_can_record := public.has_actor_authority(v_pool.parent_context_actor_id, v_caller, 'money.record');
  v_can_manage := v_pool.created_by_actor_id = v_caller
                  or public.has_actor_authority(v_pool.parent_context_actor_id, v_caller, 'context.manage');

  -- basis ledger con display_name de cada contributor
  select coalesce(jsonb_agg(jsonb_build_object(
    'basis_entry_id', pbe.id,
    'contributor_actor_id', pbe.contributor_actor_id,
    'contributor_display_name', a.display_name,
    'basis_kind', pbe.basis_kind,
    'basis_amount', pbe.basis_amount,
    'currency', pbe.currency,
    'asset_resource_id', pbe.asset_resource_id,
    'asset_display_name', r.display_name,
    'valuation_method', pbe.valuation_method,
    'valuation_notes', pbe.valuation_notes,
    'paired_obligation_id', pbe.paired_obligation_id,
    'money_transaction_id', pbe.money_transaction_id,
    'created_at', pbe.created_at,
    'resolved_at', pbe.resolved_at
  ) order by pbe.created_at asc), '[]'::jsonb)
    into v_basis_entries
    from public.pool_basis_entries pbe
    left join public.actors a on a.id = pbe.contributor_actor_id
    left join public.resources r on r.id = pbe.asset_resource_id
   where pbe.pool_account_id = v_pool.id;

  -- totales
  select jsonb_build_object(
    'basis_total', coalesce(sum(pbe.basis_amount) filter (
      where pbe.currency is not distinct from v_pool.currency or pbe.basis_kind = 'asset'
    ), 0),
    'my_basis', coalesce(sum(pbe.basis_amount) filter (
      where (pbe.currency is not distinct from v_pool.currency or pbe.basis_kind = 'asset')
        and pbe.contributor_actor_id = v_caller
    ), 0),
    'contributor_count', count(distinct pbe.contributor_actor_id),
    'entry_count', count(*)
  ) into v_totals
    from public.pool_basis_entries pbe
   where pbe.pool_account_id = v_pool.id;

  -- available_actions canónicos R.8. R.8.F cablea estas al R.7 governance catalog
  -- con sus policies (winner_takes_all=not_required, equity_target=requires_decision).
  v_actions := jsonb_build_array(
    jsonb_build_object(
      'action_key', 'pool.contribute',
      'label', 'Aportar',
      'section', 'actions',
      'enabled', v_pool.status = 'open' and v_can_record,
      'reason', case
        when v_pool.status <> 'open' then 'pool is not open'
        when not v_can_record then 'missing money.record permission'
        else null end
    ),
    jsonb_build_object(
      'action_key', 'pool.resolve',
      'label', 'Resolver fondo',
      'section', 'actions',
      'enabled', v_pool.status in ('open', 'target_reached')
                 and v_can_manage
                 and (v_totals->>'entry_count')::int > 0,
      'reason', case
        when v_pool.status not in ('open','target_reached') then 'pool already resolved or cancelled'
        when not v_can_manage then 'only creator or admin can resolve'
        when (v_totals->>'entry_count')::int = 0 then 'no basis entries to resolve'
        else null end
    ),
    jsonb_build_object(
      'action_key', 'pool.cancel',
      'label', 'Cancelar fondo',
      'section', 'actions',
      'enabled', v_pool.status = 'open' and v_can_manage,
      'reason', case
        when v_pool.status <> 'open' then 'pool is not open'
        when not v_can_manage then 'only creator or admin can cancel'
        else null end
    ),
    jsonb_build_object(
      'action_key', 'pool.update_config',
      'label', 'Configurar fondo',
      'section', 'actions',
      'enabled', v_pool.status = 'open' and v_can_manage,
      'reason', case
        when v_pool.status <> 'open' then 'pool is not open'
        when not v_can_manage then 'only creator or admin can configure'
        else null end
    )
  );

  return jsonb_build_object(
    'pool_account', jsonb_build_object(
      'pool_account_id', v_pool.id,
      'pool_actor_id', v_pool.pool_actor_id,
      'parent_context_actor_id', v_pool.parent_context_actor_id,
      'policy_key', v_pool.policy_key,
      'policy_config', v_pool.policy_config,
      'status', v_pool.status,
      'display_name', v_pool.display_name,
      'description', v_pool.description,
      'currency', v_pool.currency,
      'target_amount', v_pool.target_amount,
      'created_by_actor_id', v_pool.created_by_actor_id,
      'created_at', v_pool.created_at,
      'updated_at', v_pool.updated_at,
      'resolved_at', v_pool.resolved_at
    ),
    'basis_entries', v_basis_entries,
    'totals', v_totals,
    'available_actions', v_actions
  );
end; $$;

revoke all on function public.pool_account_detail(uuid) from public, anon;
grant execute on function public.pool_account_detail(uuid) to authenticated, service_role;

comment on function public.pool_account_detail(uuid) is
  'R.8.B: pool + basis ledger + totals + 4 available_actions canónicos.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Smoke defensivo R.8.B
-- ────────────────────────────────────────────────────────────────────────────
-- Cubre: create_pool (open) + 3 basis_kinds (cash, asset, pending_stake) +
-- list + detail + idempotency + permission denial + status open guard +
-- pending_pool no contamina settlement open count.

create or replace function public._smoke_r8_b_create_pool_basic()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  a_a uuid;
  v_ctx uuid;
  v_pool_account uuid;
  v_pool_actor uuid;
  v_result jsonb;
  v_replay jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8B PoolCreator', '+520000000800', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);

  v_ctx := ((public.create_context('_smoke_r8b Cena', 'collective', 'friend_group'))->>'context_actor_id')::uuid;

  v_result := public.create_pool(
    p_parent_context_actor_id := v_ctx,
    p_display_name := 'Bote Test',
    p_policy_key := 'winner_takes_all',
    p_currency := 'MXN',
    p_client_id := 'r8b-pool-1'
  );

  v_pool_account := (v_result->>'pool_account_id')::uuid;
  v_pool_actor := (v_result->>'pool_actor_id')::uuid;
  if v_pool_account is null or v_pool_actor is null then
    raise exception 'R.8.B create_pool: missing ids in result';
  end if;
  if (select actor_subtype from public.actors where id = v_pool_actor) <> 'pool' then
    raise exception 'R.8.B create_pool: pool actor subtype not pool';
  end if;
  if (select policy_key from public.pool_accounts where id = v_pool_account) <> 'winner_takes_all' then
    raise exception 'R.8.B create_pool: policy_key not persisted';
  end if;
  if not exists (select 1 from public.activity_events
                  where context_actor_id = v_ctx and event_type = 'pool.created'
                    and subject_id = v_pool_account) then
    raise exception 'R.8.B create_pool: activity pool.created not emitted';
  end if;

  -- Idempotency replay
  v_replay := public.create_pool(
    p_parent_context_actor_id := v_ctx,
    p_display_name := 'Bote Test',
    p_policy_key := 'winner_takes_all',
    p_currency := 'MXN',
    p_client_id := 'r8b-pool-1'
  );
  if (v_replay->>'idempotent_replay')::bool is not true then
    raise exception 'R.8.B create_pool: idempotency missed';
  end if;
  if (v_replay->>'pool_account_id')::uuid <> v_pool_account then
    raise exception 'R.8.B create_pool: idempotent replay returned different pool';
  end if;
  -- Validar que solo hay UN pool_account
  if (select count(*) from public.pool_accounts where parent_context_actor_id = v_ctx) <> 1 then
    raise exception 'R.8.B create_pool: replay creó pool duplicado';
  end if;

  -- equity_target sin target_amount debe fallar
  begin
    perform public.create_pool(v_ctx, 'JV Bad', 'equity_target');
    raise exception 'R.8.B: equity_target sin target_amount debió fallar';
  exception when sqlstate '22023' then null;
  end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a], array[u_a]);
  raise notice '_smoke_r8_b_create_pool_basic passed';
end; $$;
revoke all on function public._smoke_r8_b_create_pool_basic() from public, anon, authenticated;

create or replace function public._smoke_r8_b_contribute_three_kinds()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid;
  v_ctx uuid; v_code text;
  v_pool jsonb; v_pool_account uuid; v_pool_actor uuid;
  v_resource uuid;
  v_cash jsonb; v_asset jsonb; v_stake jsonb;
  v_open_count int;
  v_pending_pool_count int;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8B PoolA', '+520000000801', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R8B PoolB', '+520000000802', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r8b Familia', 'collective', 'family'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_pool := public.create_pool(v_ctx, 'JV Nave', 'equity_target',
    p_target_amount := 5000000, p_currency := 'MXN');
  v_pool_account := (v_pool->>'pool_account_id')::uuid;
  v_pool_actor := (v_pool->>'pool_actor_id')::uuid;

  -- Crear resource para asset contribution. Necesita resource_type catalog entry válido.
  insert into public.resources (resource_type, display_name, canonical_owner_actor_id, created_by_actor_id)
  values ('other', '_smoke_r8b Terreno', a_a, a_a)
  returning id into v_resource;

  -- 1. cash contribution (a_a)
  v_cash := public.contribute_to_pool(
    p_pool_account_id := v_pool_account,
    p_basis_kind := 'cash',
    p_amount := 1000,
    p_currency := 'MXN',
    p_client_id := 'r8b-cash-1'
  );
  if (v_cash->>'basis_entry_id') is null then raise exception 'R.8.B cash: missing basis_entry_id'; end if;
  if (v_cash->>'paired_obligation_id') is null then raise exception 'R.8.B cash: missing paired_obligation_id'; end if;
  if (v_cash->>'money_transaction_id') is null then raise exception 'R.8.B cash: missing money_transaction_id'; end if;

  -- 2. asset contribution (a_a)
  v_asset := public.contribute_to_pool(
    p_pool_account_id := v_pool_account,
    p_basis_kind := 'asset',
    p_amount := 5000000,
    p_asset_resource_id := v_resource,
    p_client_id := 'r8b-asset-1'
  );
  if (v_asset->>'basis_entry_id') is null then raise exception 'R.8.B asset: missing basis_entry_id'; end if;
  if (v_asset->>'paired_obligation_id') is not null then
    raise exception 'R.8.B asset: should NOT create obligation';
  end if;
  if (v_asset->>'money_transaction_id') is not null then
    raise exception 'R.8.B asset: should NOT create money_transaction';
  end if;
  -- valuation_method default 'manual'
  if (select valuation_method from public.pool_basis_entries where id = (v_asset->>'basis_entry_id')::uuid) <> 'manual' then
    raise exception 'R.8.B asset: valuation_method default no es manual';
  end if;

  -- 3. pending_stake contribution (a_b — el otro miembro)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_stake := public.contribute_to_pool(
    p_pool_account_id := v_pool_account,
    p_basis_kind := 'pending_stake',
    p_amount := 200,
    p_currency := 'MXN',
    p_client_id := 'r8b-stake-1'
  );
  if (v_stake->>'basis_entry_id') is null then raise exception 'R.8.B stake: missing basis_entry_id'; end if;
  if (v_stake->>'paired_obligation_id') is null then raise exception 'R.8.B stake: missing paired_obligation_id'; end if;
  if (v_stake->>'money_transaction_id') is not null then
    raise exception 'R.8.B stake: should NOT create money_transaction';
  end if;

  -- 4. Settlement batcher integration: pending_pool no debe contar como open
  select count(*) into v_open_count from public.obligations
   where context_actor_id = v_ctx and status = 'open';
  select count(*) into v_pending_pool_count from public.obligations
   where context_actor_id = v_ctx and status = 'pending_pool';
  if v_open_count <> 0 then
    raise exception 'R.8.B: pending_pool contaminó open count (% open)', v_open_count;
  end if;
  if v_pending_pool_count <> 2 then
    raise exception 'R.8.B: esperaba 2 pending_pool obligations (cash+stake), encontré %', v_pending_pool_count;
  end if;

  -- 5. activity pool.contributed (deben ser 3, una por aporte)
  if (select count(*) from public.activity_events
       where context_actor_id = v_ctx and event_type = 'pool.contributed'
         and subject_id = v_pool_account) <> 3 then
    raise exception 'R.8.B: esperaba 3 pool.contributed events';
  end if;

  -- 6. asset por non-owner debe fallar
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  begin
    perform public.contribute_to_pool(v_pool_account, 'asset', 100, p_asset_resource_id := v_resource);
    raise exception 'R.8.B: asset por non-owner debió fallar';
  exception when sqlstate '42501' then null;
  end;

  -- 7. Idempotency replay
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  if (public.contribute_to_pool(v_pool_account, 'cash', 1000, 'MXN',
       p_client_id := 'r8b-cash-1')->>'idempotent_replay')::bool is not true then
    raise exception 'R.8.B: contribute idempotency missed';
  end if;
  if (select count(*) from public.pool_basis_entries
       where pool_account_id = v_pool_account and basis_kind = 'cash'
         and contributor_actor_id = a_a) <> 1 then
    raise exception 'R.8.B: idempotency creó cash entry duplicado';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r8_b_contribute_three_kinds passed';
end; $$;
revoke all on function public._smoke_r8_b_contribute_three_kinds() from public, anon, authenticated;

create or replace function public._smoke_r8_b_list_and_detail()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  a_a uuid;
  v_ctx uuid;
  v_pool jsonb;
  v_pool_account uuid;
  v_list jsonb;
  v_detail jsonb;
  v_actions jsonb;
  v_contribute jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8B Lister', '+520000000810', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r8b List', 'collective', 'friend_group'))->>'context_actor_id')::uuid;

  v_pool := public.create_pool(v_ctx, 'Bote Listado', 'winner_takes_all', p_currency := 'MXN');
  v_pool_account := (v_pool->>'pool_account_id')::uuid;
  v_contribute := public.contribute_to_pool(v_pool_account, 'cash', 500, 'MXN');

  -- list_context_pools
  v_list := public.list_context_pools(v_ctx);
  if jsonb_typeof(v_list) <> 'array' then
    raise exception 'R.8.B list: no devolvió array';
  end if;
  if jsonb_array_length(v_list) <> 1 then
    raise exception 'R.8.B list: esperaba 1 pool, encontré %', jsonb_array_length(v_list);
  end if;
  if ((v_list->0)->'totals'->>'basis_total')::numeric <> 500 then
    raise exception 'R.8.B list: basis_total wrong';
  end if;
  if ((v_list->0)->'totals'->>'my_basis')::numeric <> 500 then
    raise exception 'R.8.B list: my_basis wrong';
  end if;
  if ((v_list->0)->'totals'->>'contributor_count')::int <> 1 then
    raise exception 'R.8.B list: contributor_count wrong';
  end if;

  -- pool_account_detail
  v_detail := public.pool_account_detail(v_pool_account);
  if (v_detail->'pool_account'->>'display_name') <> 'Bote Listado' then
    raise exception 'R.8.B detail: display_name wrong';
  end if;
  if jsonb_array_length(v_detail->'basis_entries') <> 1 then
    raise exception 'R.8.B detail: esperaba 1 basis entry';
  end if;
  if (v_detail->'totals'->>'basis_total')::numeric <> 500 then
    raise exception 'R.8.B detail: basis_total wrong';
  end if;

  v_actions := v_detail->'available_actions';
  if jsonb_array_length(v_actions) <> 4 then
    raise exception 'R.8.B detail: esperaba 4 available_actions';
  end if;

  -- pool.contribute debe estar enabled (status=open + caller has money.record)
  if not ((v_actions->0)->>'enabled')::bool then
    raise exception 'R.8.B detail: pool.contribute debió estar enabled';
  end if;
  -- pool.resolve debe estar enabled (creator + entry_count > 0)
  if not ((v_actions->1)->>'enabled')::bool then
    raise exception 'R.8.B detail: pool.resolve debió estar enabled';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a], array[u_a]);
  raise notice '_smoke_r8_b_list_and_detail passed';
end; $$;
revoke all on function public._smoke_r8_b_list_and_detail() from public, anon, authenticated;

create or replace function public._smoke_r8_b_permission_denial()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  u_outsider uuid := gen_random_uuid();
  a_a uuid;
  a_outsider uuid;
  v_ctx uuid;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8B Owner', '+520000000820', null);
  a_outsider := public._create_person_actor_for_auth_user(u_outsider, 'R8B Outsider', '+520000000821', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r8b PermCtx', 'collective', 'friend_group'))->>'context_actor_id')::uuid;

  -- outsider intenta crear pool en contexto donde no es miembro
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_outsider::text)::text, true);
  begin
    perform public.create_pool(v_ctx, 'Bote Ilegal', 'winner_takes_all');
    raise exception 'R.8.B: outsider creó pool sin ser miembro';
  exception when sqlstate '42501' then null;
  end;

  -- unauthenticated
  perform set_config('request.jwt.claims', null, true);
  begin
    perform public.create_pool(v_ctx, 'Bote NoAuth', 'winner_takes_all');
    raise exception 'R.8.B: unauthenticated debió fallar';
  exception when sqlstate '28000' then null;
  end;

  perform public._r2_cleanup_context(v_ctx, array[a_a, a_outsider], array[u_a, u_outsider]);
  raise notice '_smoke_r8_b_permission_denial passed';
end; $$;
revoke all on function public._smoke_r8_b_permission_denial() from public, anon, authenticated;

-- Wrapper CI
create or replace function public._smoke_mvp2_r8_b_pool_rpcs_core()
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
  perform public._smoke_r8_b_create_pool_basic();
  perform public._smoke_r8_b_contribute_three_kinds();
  perform public._smoke_r8_b_list_and_detail();
  perform public._smoke_r8_b_permission_denial();
  raise notice 'R.8.B POOL RPCs CORE: PASS — create_pool + contribute (cash/asset/stake) + list + detail + idempotency + permission gate + pending_pool isolated from open.';
end; $$;
revoke all on function public._smoke_mvp2_r8_b_pool_rpcs_core() from public, anon, authenticated;

comment on function public._smoke_mvp2_r8_b_pool_rpcs_core() is
  'R.8.B DoD: 4 RPCs integrados a money primitives existentes (transaction_type=contribution / obligation_type=contribution / money.record gate / activity catalog).';
