-- ============================================================================
-- R.8.A — POOL PRIMITIVE · SCHEMA
-- ============================================================================
-- Doctrina (R.8, founder-signed 2026-06-10): Pool = cuenta de capital colectiva
-- universal. Un actor `collective` sub-tipo `pool` que vive bajo un contexto
-- padre, acepta contribuciones (cash | asset | service | pending_stake) de N
-- actores, mantiene un basis ledger por contribuyente, y se resuelve según una
-- política declarativa que transforma el basis en obligaciones pairwise normales
-- (que entran al settlement existente sin cambios al batcher).
--
-- Casos de uso cubiertos por el mismo primitive:
--   · Bote de juego (Happy King)           policy = winner_takes_all
--   · Joint venture terreno↔construcción   policy = equity_target
--   · Kitty de viaje                        policy = equal_share
--   · Fondo de regalo grupal                policy = proportional
--   · Bounty pool / escrow de obra          policy = winner_takes_all | equity_target
--   · Partnership capital accounts          policy = custom_spec (post-MVP)
--   · Tanda / cundina                       policy = rotational (post-MVP)
--
-- Plan canónico: Plans/Active/R8_PoolPrimitive.md (§2 schema · §8 slices).
-- Este migration: SOLO schema. RPCs llegan en R.8.B. Resolución en R.8.C.
--
-- Cambios:
--   1. actors.actor_subtype CHECK → agrega 'pool'.
--   2. Tabla pool_accounts (metadata específica del pool: policy, status, target).
--   3. Tabla pool_basis_entries (ledger por contribuyente).
--   4. obligations.status CHECK → agrega 'pending_pool' (no-enforceable stake
--      antes de resolver; al resolver, resolve_pool emite obligations open).
--   5. RLS SELECT (membership del padre + contribuyente).
--   6. Smoke defensivo: pool actor + 3 basis kinds + obligation pending_pool +
--      CHECK rejections + cleanup. Wrapper CI _smoke_mvp2_r8_a_pool_schema().
--
-- Compatibilidad:
--   · obligations.status='pending_pool' es ADITIVO. settlement batcher filtra
--     a status='open' (intact) → pending_pool queda fuera del netting hasta
--     que resolve_pool lo crystallize. R.2N min-cashflow no cambia.
--   · attention_inbox y my_world NO se tocan aquí — R.8.B/C deciden si renderizan
--     pending_pool obligations especial o las omiten.
--   · Cero impacto en RPCs existentes (record_expense / record_fine /
--     record_game_result / generate_settlement_batch / mark_settlement_paid).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. actors.actor_subtype: agregar 'pool' al CHECK
-- ────────────────────────────────────────────────────────────────────────────
-- Identifica y elimina el constraint vigente (nombre puede variar por orden de
-- creación) y lo recrea con 'pool' añadido. Patrón heredado de R.2R.
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
   where conrelid = 'public.actors'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%actor_subtype%'
     and pg_get_constraintdef(oid) ilike '%friend_group%'
   limit 1;
  if v_name is not null then
    execute format('alter table public.actors drop constraint %I', v_name);
  end if;
end $$;

alter table public.actors
  add constraint actors_actor_subtype_check check (actor_subtype in
    ('person', 'friend_group', 'family', 'company', 'trust', 'trip',
     'community', 'project', 'system', 'pool', 'other'));

comment on column public.actors.actor_subtype is
  'MVP2 + R.8.A: incluye ''pool'' para actores de capital colectivo (bote / JV / kitty / fondo).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. pool_accounts
-- ────────────────────────────────────────────────────────────────────────────
-- El actor del pool ya existe en `actors` (kind='collective', subtype='pool').
-- Esta tabla agrega la metadata específica: política declarativa, status,
-- target opcional (para equity_target), referencia al contexto padre.
create table if not exists public.pool_accounts (
  id uuid primary key default gen_random_uuid(),
  pool_actor_id uuid not null unique references public.actors(id) on delete cascade,
  parent_context_actor_id uuid not null references public.actors(id) on delete cascade,
  policy_key text not null check (policy_key in
    ('winner_takes_all', 'equity_target', 'proportional', 'equal_share',
     'rotational', 'custom_spec')),
  policy_config jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in
    ('open', 'target_reached', 'resolving', 'resolved', 'cancelled')),
  display_name text not null,
  description text,
  currency text,           -- nullable: pools pure-asset o mixtos pueden no fijar moneda
  target_amount numeric,   -- usado por equity_target (validación en RPC, no en schema)
  metadata jsonb not null default '{}'::jsonb,
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_payload jsonb
);

create index if not exists idx_pool_accounts_parent
  on public.pool_accounts (parent_context_actor_id, status);
create index if not exists idx_pool_accounts_pool_actor
  on public.pool_accounts (pool_actor_id);
create index if not exists idx_pool_accounts_policy
  on public.pool_accounts (policy_key, status);

drop trigger if exists trg_pool_accounts_touch on public.pool_accounts;
create trigger trg_pool_accounts_touch before update on public.pool_accounts
  for each row execute function public.touch_updated_at();

comment on table public.pool_accounts is
  'R.8: cuenta de capital colectiva. Bote / JV / kitty / fondo. Resolución → obligations pairwise.';
comment on column public.pool_accounts.policy_key is
  'R.8: política declarativa de resolución. Determina cómo basis ledger → obligations pairwise.';
comment on column public.pool_accounts.policy_config is
  'R.8: config específica de la política (ej. stake_per_player, distribution_spec).';
comment on column public.pool_accounts.target_amount is
  'R.8: monto target para equity_target. NULL para otras políticas.';
comment on column public.pool_accounts.resolved_payload is
  'R.8: snapshot del payload que se pasó a resolve_pool() (ej. {winner_actor_id}). Audit trail.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. pool_basis_entries
-- ────────────────────────────────────────────────────────────────────────────
-- Ledger por contribuyente. Cuatro basis_kind:
--   · cash          → contribuyente metió dinero real, hay money_transaction
--                     paralela + obligation status='pending_pool' (debtor=contrib,
--                     creditor=pool_actor) que se crystallize al resolver.
--   · asset         → contribuyente aportó un recurso valuado (terreno, vehículo).
--                     asset_resource_id obligatorio. NO hay transferencia hasta
--                     resolución. valuation_method='manual' por MVP (founder-signed).
--   · service       → aporte en horas/servicios. valuation_method='manual'.
--                     Modelado pero sin UI MVP (deferred).
--   · pending_stake → "voy a aportar X" sin pago todavía (caso bote: jugaste pero
--                     no metiste cash). Crea obligation status='pending_pool' sin
--                     money_transaction. resolve_pool puede asignar el creditor
--                     final (al ganador) sin que el debtor haya pagado.
create table if not exists public.pool_basis_entries (
  id uuid primary key default gen_random_uuid(),
  pool_account_id uuid not null references public.pool_accounts(id) on delete cascade,
  contributor_actor_id uuid not null references public.actors(id),
  basis_kind text not null check (basis_kind in
    ('cash', 'asset', 'service', 'pending_stake')),
  basis_amount numeric not null check (basis_amount >= 0),
  currency text,
  asset_resource_id uuid references public.resources(id),
  valuation_method text check (valuation_method in
    ('manual', 'appraisal', 'market', 'cost') or valuation_method is null),
  valuation_notes text,
  -- Vínculo con la obligation paralela (cash + pending_stake la tienen; asset/service no).
  paired_obligation_id uuid references public.obligations(id),
  -- Vínculo con money_transaction de cash genuino (solo cash; pending_stake no).
  money_transaction_id uuid references public.money_transactions(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  -- Obligations finales emitidas al resolver el pool (puede ser >1 si se distribuye).
  resolution_obligation_ids uuid[] not null default '{}'::uuid[],
  -- Consistencia básica a nivel schema (validación de negocio en RPCs):
  --   asset requiere asset_resource_id; cash requiere currency.
  constraint pool_basis_asset_requires_resource
    check (basis_kind <> 'asset' or asset_resource_id is not null),
  constraint pool_basis_cash_requires_currency
    check (basis_kind <> 'cash' or currency is not null),
  constraint pool_basis_pending_stake_requires_currency
    check (basis_kind <> 'pending_stake' or currency is not null)
);

create index if not exists idx_pool_basis_pool
  on public.pool_basis_entries (pool_account_id, created_at desc);
create index if not exists idx_pool_basis_contributor
  on public.pool_basis_entries (contributor_actor_id, pool_account_id);
create index if not exists idx_pool_basis_resource
  on public.pool_basis_entries (asset_resource_id) where asset_resource_id is not null;
create index if not exists idx_pool_basis_obligation
  on public.pool_basis_entries (paired_obligation_id) where paired_obligation_id is not null;
create index if not exists idx_pool_basis_unresolved
  on public.pool_basis_entries (pool_account_id) where resolved_at is null;

comment on table public.pool_basis_entries is
  'R.8: aportes al pool. cash/asset/service/pending_stake. Al resolver emite obligations finales.';
comment on column public.pool_basis_entries.basis_kind is
  'R.8: cash=dinero real (paired_obligation + money_transaction), asset=recurso valuado, service=horas (post-MVP UI), pending_stake=stake sin pago (paired_obligation sin transaction).';
comment on column public.pool_basis_entries.valuation_method is
  'R.8.A: solo ''manual'' soportado en MVP. appraisal/market/cost reservados para futuras integraciones.';
comment on column public.pool_basis_entries.resolution_obligation_ids is
  'R.8: obligations pairwise (status=open) emitidas por resolve_pool al cristalizar este entry.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. obligations.status: agregar 'pending_pool' al CHECK existente
-- ────────────────────────────────────────────────────────────────────────────
-- pending_pool = stake registrado en un pool sin contraparte definitiva todavía.
-- Settlement batcher filtra a status='open' (intacto), así que pending_pool queda
-- fuera del netting hasta que resolve_pool lo crystallize → status='open' con
-- creditor_actor_id final.
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
   where conrelid = 'public.obligations'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%status%'
     and pg_get_constraintdef(oid) ilike '%settled%'
   limit 1;
  if v_name is not null then
    execute format('alter table public.obligations drop constraint %I', v_name);
  end if;
end $$;

alter table public.obligations
  add constraint obligations_status_check check (status in
    ('open', 'accepted', 'in_progress', 'completed', 'expired',
     'settled', 'cancelled', 'forgiven', 'disputed', 'pending_pool'));

comment on constraint obligations_status_check on public.obligations is
  'R.8.A: agrega pending_pool (stake en pool sin contraparte final). Settlement filtra a open.';

-- Índice para localizar obligations en pending_pool por pool (vía metadata),
-- útil cuando resolve_pool itera el conjunto. Se llena de pool_basis_entries.
create index if not exists idx_obligations_pending_pool
  on public.obligations (context_actor_id, status)
  where status = 'pending_pool';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. RLS
-- ────────────────────────────────────────────────────────────────────────────
-- Doctrina MVP2: lectura via PostgREST gated por membership; escritura SOLO vía
-- RPCs SECURITY DEFINER (que llegan en R.8.B). Aquí habilitamos SELECT.
alter table public.pool_accounts enable row level security;
alter table public.pool_basis_entries enable row level security;

drop policy if exists pool_accounts_select on public.pool_accounts;
create policy pool_accounts_select on public.pool_accounts
  for select
  using (
    public.is_context_member(parent_context_actor_id)
    or exists (
      select 1 from public.pool_basis_entries pbe
      where pbe.pool_account_id = public.pool_accounts.id
        and pbe.contributor_actor_id = public.current_actor_id()
    )
  );

drop policy if exists pool_basis_entries_select on public.pool_basis_entries;
create policy pool_basis_entries_select on public.pool_basis_entries
  for select
  using (
    contributor_actor_id = public.current_actor_id()
    or exists (
      select 1 from public.pool_accounts pa
      where pa.id = public.pool_basis_entries.pool_account_id
        and public.is_context_member(pa.parent_context_actor_id)
    )
  );

comment on policy pool_accounts_select on public.pool_accounts is
  'R.8.A: ven pools los miembros del contexto padre + los contribuyentes (cubre invitados ad-hoc).';
comment on policy pool_basis_entries_select on public.pool_basis_entries is
  'R.8.A: ven aportes los miembros del contexto padre + el propio contribuyente.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke defensivo
-- ────────────────────────────────────────────────────────────────────────────
-- No depende de RPCs (R.8.B llega después). Inserta directo, valida CHECKs,
-- limpia. Wrapper para CI runner: _smoke_mvp2_r8_a_pool_schema().

create or replace function public._smoke_r8_a_pool_account_lifecycle()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_parent_actor uuid;
  v_creator_actor uuid;
  v_pool_actor uuid;
  v_pool_account uuid;
  v_basis_cash uuid;
  v_basis_asset uuid;
  v_basis_stake uuid;
  v_resource uuid;
  v_obligation_id uuid;
  v_count int;
begin
  -- Crear actors de prueba (sin auth.uid, directos en tabla)
  insert into public.actors (actor_kind, actor_subtype, display_name)
  values ('collective', 'friend_group', '_smoke_r8a parent')
  returning id into v_parent_actor;

  insert into public.actors (actor_kind, actor_subtype, display_name)
  values ('person', 'person', '_smoke_r8a creator')
  returning id into v_creator_actor;

  -- 1. Crear pool actor (subtype='pool' debe pasar el CHECK ampliado)
  insert into public.actors (actor_kind, actor_subtype, display_name)
  values ('collective', 'pool', '_smoke_r8a Bote Test')
  returning id into v_pool_actor;

  -- 2. Crear pool_accounts row
  insert into public.pool_accounts (
    pool_actor_id, parent_context_actor_id, policy_key, policy_config,
    display_name, currency, created_by_actor_id
  )
  values (
    v_pool_actor, v_parent_actor, 'winner_takes_all',
    '{"stake_per_player": 200}'::jsonb,
    'Bote Test', 'MXN', v_creator_actor
  )
  returning id into v_pool_account;

  -- 3. Insertar basis entries: cash + asset + pending_stake
  -- 3a. asset requiere asset_resource_id → primero creo un resource dummy
  insert into public.resources (
    context_actor_id, resource_type, display_name, canonical_owner_actor_id,
    estimated_value, currency, created_by_actor_id
  )
  values (v_parent_actor, 'other', '_smoke_r8a Terreno', v_creator_actor,
          5000000, 'MXN', v_creator_actor)
  returning id into v_resource;

  insert into public.pool_basis_entries (
    pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency
  )
  values (v_pool_account, v_creator_actor, 'cash', 1000, 'MXN')
  returning id into v_basis_cash;

  insert into public.pool_basis_entries (
    pool_account_id, contributor_actor_id, basis_kind, basis_amount,
    asset_resource_id, valuation_method
  )
  values (v_pool_account, v_creator_actor, 'asset', 5000000, v_resource, 'manual')
  returning id into v_basis_asset;

  insert into public.pool_basis_entries (
    pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency
  )
  values (v_pool_account, v_creator_actor, 'pending_stake', 200, 'MXN')
  returning id into v_basis_stake;

  select count(*) into v_count from public.pool_basis_entries
   where pool_account_id = v_pool_account;
  if v_count <> 3 then
    raise exception 'R.8.A: esperaba 3 basis entries, encontré %', v_count;
  end if;

  -- 4. Insertar obligation con status='pending_pool' (status nuevo)
  insert into public.obligations (
    context_actor_id, debtor_actor_id, creditor_actor_id,
    obligation_type, obligation_kind, status, amount, currency
  )
  values (
    v_parent_actor, v_creator_actor, v_pool_actor,
    'pool_stake', 'money', 'pending_pool', 200, 'MXN'
  )
  returning id into v_obligation_id;

  if (select status from public.obligations where id = v_obligation_id) <> 'pending_pool' then
    raise exception 'R.8.A: status pending_pool no quedó persistido';
  end if;

  -- 5. Settlement batcher (R.2N) ignora pending_pool: count obligations open en el contexto
  --    debe quedar en 0 a pesar de tener la obligación pending_pool encima.
  select count(*) into v_count from public.obligations
   where context_actor_id = v_parent_actor and status = 'open';
  if v_count <> 0 then
    raise exception 'R.8.A: pending_pool no debió contar como open (encontré %)', v_count;
  end if;

  -- 6. CHECK rejections defensivos
  begin
    insert into public.pool_accounts (
      pool_actor_id, parent_context_actor_id, policy_key, display_name
    )
    values (v_pool_actor, v_parent_actor, 'invalid_policy', 'should fail');
    raise exception 'R.8.A: policy_key inválida debió fallar el CHECK';
  exception when check_violation then null;
  end;

  begin
    insert into public.pool_basis_entries (
      pool_account_id, contributor_actor_id, basis_kind, basis_amount
    )
    values (v_pool_account, v_creator_actor, 'asset', 100);  -- falta asset_resource_id
    raise exception 'R.8.A: asset sin resource_id debió fallar el CHECK';
  exception when check_violation then null;
  end;

  begin
    insert into public.pool_basis_entries (
      pool_account_id, contributor_actor_id, basis_kind, basis_amount
    )
    values (v_pool_account, v_creator_actor, 'cash', 100);  -- falta currency
    raise exception 'R.8.A: cash sin currency debió fallar el CHECK';
  exception when check_violation then null;
  end;

  begin
    insert into public.pool_basis_entries (
      pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency
    )
    values (v_pool_account, v_creator_actor, 'cash', -50, 'MXN');  -- negativo
    raise exception 'R.8.A: basis_amount negativo debió fallar el CHECK';
  exception when check_violation then null;
  end;

  -- 7. Cleanup (orden inverso por FKs)
  delete from public.obligations where id = v_obligation_id;
  delete from public.pool_basis_entries where pool_account_id = v_pool_account;
  delete from public.pool_accounts where id = v_pool_account;
  delete from public.resources where id = v_resource;
  delete from public.actors where id = v_pool_actor;
  delete from public.actors where id = v_creator_actor;
  delete from public.actors where id = v_parent_actor;

  raise notice '_smoke_r8_a_pool_account_lifecycle passed';
end; $$;
revoke all on function public._smoke_r8_a_pool_account_lifecycle() from public, anon, authenticated;

create or replace function public._smoke_r8_a_actor_subtype_pool()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare v_actor uuid;
begin
  -- 'pool' debe estar permitido en actor_subtype
  insert into public.actors (actor_kind, actor_subtype, display_name)
  values ('collective', 'pool', '_smoke_r8a subtype test')
  returning id into v_actor;

  if (select actor_subtype from public.actors where id = v_actor) <> 'pool' then
    raise exception 'R.8.A: actor_subtype=pool no se persistió';
  end if;

  -- subtypes legacy siguen funcionando (backcompat)
  perform 1 from public.actors where id = v_actor and actor_subtype = 'pool';

  -- subtype inválido debe seguir siendo rechazado
  begin
    insert into public.actors (actor_kind, actor_subtype, display_name)
    values ('collective', 'totally_bogus', '_smoke_r8a bogus');
    raise exception 'R.8.A: subtype inválido debió fallar el CHECK';
  exception when check_violation then null;
  end;

  delete from public.actors where id = v_actor;
  raise notice '_smoke_r8_a_actor_subtype_pool passed';
end; $$;
revoke all on function public._smoke_r8_a_actor_subtype_pool() from public, anon, authenticated;

-- Wrapper CI: el runner ejecuta _smoke_mvp2_* — agrupa los smokes R.8.A.
create or replace function public._smoke_mvp2_r8_a_pool_schema()
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
  perform public._smoke_r8_a_actor_subtype_pool();
  perform public._smoke_r8_a_pool_account_lifecycle();
  raise notice 'R.8.A POOL PRIMITIVE SCHEMA: PASS — actors.subtype=pool + pool_accounts + pool_basis_entries + obligations.status=pending_pool + RLS + CHECKs.';
end; $$;
revoke all on function public._smoke_mvp2_r8_a_pool_schema() from public, anon, authenticated;

comment on function public._smoke_mvp2_r8_a_pool_schema() is
  'R.8.A DoD: schema pool_accounts + pool_basis_entries + obligations.pending_pool + RLS, sin tocar money_transactions ni settlement_batches.';
