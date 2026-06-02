-- ============================================================================
-- MVP 2.0 — M.9 MONEY
-- ============================================================================
-- money_transactions + money_splits + settlement_batches + settlement_items +
-- RPCs: record_expense (split automático → obligations) / record_fine /
-- record_game_result / generate_settlement_batch (greedy min-cashflow) /
-- mark_settlement_paid + RLS + smoke.
-- ============================================================================

create table public.money_transactions (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid references public.actors(id) on delete cascade,
  from_actor_id uuid references public.actors(id),
  to_actor_id uuid references public.actors(id),
  transaction_type text not null check (transaction_type in
    ('expense', 'payment', 'settlement', 'contribution', 'payout', 'game_result', 'other')),
  amount numeric not null check (amount > 0),
  currency text not null,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  occurred_at timestamptz not null default now(),
  resource_id uuid references public.resources(id),
  decision_id uuid references public.decisions(id),
  event_id uuid references public.calendar_events(id),
  obligation_id uuid references public.obligations(id),
  metadata jsonb not null default '{}',
  client_id text,
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_txn_context on public.money_transactions (context_actor_id, occurred_at desc);
create unique index idx_txn_client_id on public.money_transactions (created_by_actor_id, client_id) where client_id is not null;

create trigger trg_txn_touch before update on public.money_transactions
  for each row execute function public.touch_updated_at();

create table public.money_splits (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.money_transactions(id) on delete cascade,
  actor_id uuid not null references public.actors(id),
  split_role text not null check (split_role in ('payer', 'beneficiary', 'debtor', 'creditor', 'excluded')),
  amount numeric not null,
  currency text not null,
  metadata jsonb not null default '{}'
);

create index idx_splits_txn on public.money_splits (transaction_id);

create table public.settlement_batches (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid references public.actors(id) on delete cascade,
  status text not null default 'draft' check (status in ('draft', 'finalized', 'cancelled')),
  currency text not null,
  metadata jsonb not null default '{}',
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  finalized_at timestamptz
);

create table public.settlement_items (
  id uuid primary key default gen_random_uuid(),
  settlement_batch_id uuid not null references public.settlement_batches(id) on delete cascade,
  from_actor_id uuid not null references public.actors(id),
  to_actor_id uuid not null references public.actors(id),
  amount numeric not null check (amount > 0),
  currency text not null,
  status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled')),
  settled_transaction_id uuid references public.money_transactions(id),
  metadata jsonb not null default '{}'
);

create index idx_settlement_items_batch on public.settlement_items (settlement_batch_id);

-- ────────────────────────────────────────────────────────────────────────────
-- RPCs
-- ────────────────────────────────────────────────────────────────────────────
-- record_expense: el caller pagó; se divide en partes iguales entre los
-- participantes (default: todos los miembros activos) → obligations expense_share
create or replace function public.record_expense(
  p_context_actor_id uuid,
  p_amount numeric,
  p_currency text,
  p_description text,
  p_split_with uuid[] default null,
  p_event_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_txn uuid;
  v_existing uuid;
  v_participants uuid[];
  v_share numeric;
  v_p uuid;
  v_obligations jsonb := '[]'::jsonb;
  v_ob uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to record money in context %', p_context_actor_id using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.money_transactions
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('transaction_id', v_existing, 'idempotent_replay', true);
    end if;
  end if;

  -- participantes del split: explícitos o todos los miembros activos
  if p_split_with is not null and array_length(p_split_with, 1) > 0 then
    v_participants := p_split_with;
  else
    select array_agg(member_actor_id) into v_participants
      from public.actor_memberships
     where context_actor_id = p_context_actor_id and membership_status = 'active';
  end if;
  if v_participants is null or array_length(v_participants, 1) = 0 then
    v_participants := array[v_caller];
  end if;
  -- el payer siempre participa
  if not v_caller = any(v_participants) then
    v_participants := v_participants || v_caller;
  end if;

  v_share := round(p_amount / array_length(v_participants, 1), 2);

  insert into public.money_transactions
    (context_actor_id, from_actor_id, transaction_type, amount, currency,
     event_id, metadata, client_id, created_by_actor_id)
  values
    (p_context_actor_id, v_caller, 'expense', p_amount, p_currency,
     p_event_id, coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('description', p_description),
     p_client_id, v_caller)
  returning id into v_txn;

  -- splits: payer + beneficiaries
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, v_caller, 'payer', p_amount, p_currency);

  foreach v_p in array v_participants loop
    insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
    values (v_txn, v_p, 'beneficiary', v_share, p_currency);

    -- cada participante (≠ payer) le debe su parte al payer
    if v_p <> v_caller then
      insert into public.obligations
        (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
         amount, currency, source_event_id, metadata)
      values
        (p_context_actor_id, v_p, v_caller, 'expense_share', v_share, p_currency, p_event_id,
         jsonb_build_object('transaction_id', v_txn, 'description', p_description))
      returning id into v_ob;
      v_obligations := v_obligations || jsonb_build_object('obligation_id', v_ob, 'debtor', v_p, 'amount', v_share);
    end if;
  end loop;

  perform public._emit_activity(p_context_actor_id, v_caller, 'money.expense_recorded', 'money_transaction', v_txn,
    jsonb_build_object('amount', p_amount, 'currency', p_currency, 'description', p_description,
                       'split_count', array_length(v_participants, 1)));

  return jsonb_build_object('transaction_id', v_txn, 'share_per_person', v_share, 'obligations', v_obligations);
end; $$;

revoke all on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text) from public, anon;
grant execute on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text) to authenticated, service_role;

-- record_fine: multa manual (a otro requiere members.manage)
create or replace function public.record_fine(
  p_context_actor_id uuid,
  p_debtor_actor_id uuid,
  p_amount numeric,
  p_currency text,
  p_reason text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to record money' using errcode = '42501';
  end if;
  if p_debtor_actor_id <> v_caller
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'fining others requires members.manage' using errcode = '42501';
  end if;

  insert into public.obligations
    (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, metadata)
  values
    (p_context_actor_id, p_debtor_actor_id, p_context_actor_id, 'fine', p_amount, p_currency,
     jsonb_build_object('reason', p_reason, 'issued_by', v_caller))
  returning id into v_ob;

  perform public._emit_activity(p_context_actor_id, v_caller, 'money.fine_recorded', 'obligation', v_ob,
    jsonb_build_object('debtor', p_debtor_actor_id, 'amount', p_amount, 'reason', p_reason),
    p_obligation_id := v_ob);

  return jsonb_build_object('obligation_id', v_ob);
end; $$;

revoke all on function public.record_fine(uuid, uuid, numeric, text, text) from public, anon;
grant execute on function public.record_fine(uuid, uuid, numeric, text, text) to authenticated, service_role;

-- record_game_result: [{actor_id, amount}] — negativos deben, positivos reciben.
-- Crea game_debt obligations de perdedores a ganadores (proporcional).
create or replace function public.record_game_result(
  p_context_actor_id uuid,
  p_results jsonb,
  p_event_id uuid default null,
  p_currency text default 'MXN'
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_total_won numeric := 0;
  v_total_lost numeric := 0;
  v_loser record;
  v_winner record;
  v_ob uuid;
  v_obligations jsonb := '[]'::jsonb;
  v_share numeric;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to record money' using errcode = '42501';
  end if;

  select coalesce(sum((r->>'amount')::numeric) filter (where (r->>'amount')::numeric > 0), 0),
         coalesce(abs(sum((r->>'amount')::numeric) filter (where (r->>'amount')::numeric < 0)), 0)
    into v_total_won, v_total_lost
    from jsonb_array_elements(p_results) r;

  if v_total_won = 0 or v_total_lost = 0 then
    raise exception 'game results must have winners and losers' using errcode = '22023';
  end if;

  -- cada perdedor le debe a cada ganador proporcionalmente
  for v_loser in
    select (r->>'actor_id')::uuid as actor_id, abs((r->>'amount')::numeric) as lost
      from jsonb_array_elements(p_results) r where (r->>'amount')::numeric < 0
  loop
    for v_winner in
      select (r->>'actor_id')::uuid as actor_id, (r->>'amount')::numeric as won
        from jsonb_array_elements(p_results) r where (r->>'amount')::numeric > 0
    loop
      v_share := round(v_loser.lost * (v_winner.won / v_total_won), 2);
      if v_share > 0 then
        insert into public.obligations
          (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
           amount, currency, source_event_id, metadata)
        values
          (p_context_actor_id, v_loser.actor_id, v_winner.actor_id, 'game_debt',
           v_share, p_currency, p_event_id,
           jsonb_build_object('recorded_by', v_caller))
        returning id into v_ob;
        v_obligations := v_obligations || jsonb_build_object(
          'obligation_id', v_ob, 'debtor', v_loser.actor_id, 'creditor', v_winner.actor_id, 'amount', v_share);
      end if;
    end loop;
  end loop;

  perform public._emit_activity(p_context_actor_id, v_caller, 'money.game_result_recorded', 'calendar_event', p_event_id,
    jsonb_build_object('results', p_results, 'obligations_created', jsonb_array_length(v_obligations)));

  return jsonb_build_object('obligations', v_obligations);
end; $$;

revoke all on function public.record_game_result(uuid, jsonb, uuid, text) from public, anon;
grant execute on function public.record_game_result(uuid, jsonb, uuid, text) to authenticated, service_role;

-- generate_settlement_batch: neteo greedy min-cashflow de obligations abiertas
create or replace function public.generate_settlement_batch(
  p_context_actor_id uuid,
  p_currency text
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_batch uuid;
  v_items jsonb := '[]'::jsonb;
  v_debtors record;
  v_creditors record;
  v_amount numeric;
  -- arrays de trabajo (greedy)
  v_net_debtors uuid[];  v_net_debtor_amounts numeric[];
  v_net_creditors uuid[]; v_net_creditor_amounts numeric[];
  i integer; j integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to settle in context %', p_context_actor_id using errcode = '42501';
  end if;

  -- neto por actor: positivo = le deben, negativo = debe
  create temp table _net on commit drop as
  select actor_id, sum(net) as net from (
    select creditor_actor_id as actor_id, sum(amount) as net
      from public.obligations
     where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency
     group by creditor_actor_id
    union all
    select debtor_actor_id, -sum(amount)
      from public.obligations
     where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency
     group by debtor_actor_id
  ) x group by actor_id having abs(sum(net)) > 0.01;

  if not exists (select 1 from _net) then
    return jsonb_build_object('batch_id', null, 'items', '[]'::jsonb, 'message', 'nothing to settle');
  end if;

  insert into public.settlement_batches (context_actor_id, currency, created_by_actor_id)
  values (p_context_actor_id, p_currency, v_caller)
  returning id into v_batch;

  -- greedy: ordenar deudores y acreedores por monto desc, emparejar
  select array_agg(actor_id order by net), array_agg(-net order by net)
    into v_net_debtors, v_net_debtor_amounts
    from _net where net < 0;
  select array_agg(actor_id order by net desc), array_agg(net order by net desc)
    into v_net_creditors, v_net_creditor_amounts
    from _net where net > 0;

  i := 1; j := 1;
  while i <= coalesce(array_length(v_net_debtors, 1), 0)
    and j <= coalesce(array_length(v_net_creditors, 1), 0) loop
    v_amount := least(v_net_debtor_amounts[i], v_net_creditor_amounts[j]);
    if v_amount > 0.01 then
      insert into public.settlement_items
        (settlement_batch_id, from_actor_id, to_actor_id, amount, currency)
      values (v_batch, v_net_debtors[i], v_net_creditors[j], round(v_amount, 2), p_currency);
      v_items := v_items || jsonb_build_object(
        'from', v_net_debtors[i], 'to', v_net_creditors[j], 'amount', round(v_amount, 2));
    end if;
    v_net_debtor_amounts[i] := v_net_debtor_amounts[i] - v_amount;
    v_net_creditor_amounts[j] := v_net_creditor_amounts[j] - v_amount;
    if v_net_debtor_amounts[i] <= 0.01 then i := i + 1; end if;
    if v_net_creditor_amounts[j] <= 0.01 then j := j + 1; end if;
  end loop;

  perform public._emit_activity(p_context_actor_id, v_caller, 'money.settlement_generated', 'settlement_batch', v_batch,
    jsonb_build_object('currency', p_currency, 'items', jsonb_array_length(v_items)));

  return jsonb_build_object('batch_id', v_batch, 'items', v_items);
end; $$;

revoke all on function public.generate_settlement_batch(uuid, text) from public, anon;
grant execute on function public.generate_settlement_batch(uuid, text) to authenticated, service_role;

-- mark_settlement_paid: el deudor (o admin) marca pagado → transaction + cierra obligations FIFO
create or replace function public.mark_settlement_paid(p_settlement_item_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_txn uuid;
  v_remaining numeric;
  v_ob record;
  v_closed integer := 0;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  if v_item.status = 'paid' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_paid', true);
  end if;

  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id;

  -- autorización: el deudor del item, o quien tenga money.settle en el contexto
  if v_item.from_actor_id <> v_caller
     and not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to mark this settlement as paid' using errcode = '42501';
  end if;

  -- transacción de settlement
  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency, created_by_actor_id, metadata)
  values
    (v_batch.context_actor_id, v_item.from_actor_id, v_item.to_actor_id, 'settlement',
     v_item.amount, v_item.currency, v_caller,
     jsonb_build_object('settlement_item_id', p_settlement_item_id))
  returning id into v_txn;

  update public.settlement_items
     set status = 'paid', settled_transaction_id = v_txn
   where id = p_settlement_item_id;

  -- cerrar obligations FIFO hasta cubrir el monto
  -- (obligations directas del deudor al acreedor + las que el deudor debe al contexto
  --  cuando el acreedor del item es quien cobra en nombre del contexto)
  v_remaining := v_item.amount;
  for v_ob in
    select id, amount from public.obligations
    where context_actor_id = v_batch.context_actor_id
      and debtor_actor_id = v_item.from_actor_id
      and (creditor_actor_id = v_item.to_actor_id or creditor_actor_id = v_batch.context_actor_id)
      and status = 'open' and currency = v_item.currency
    order by created_at
  loop
    exit when v_remaining <= 0.01;
    if v_ob.amount <= v_remaining + 0.01 then
      update public.obligations set status = 'settled',
        metadata = metadata || jsonb_build_object('settled_by_transaction', v_txn)
       where id = v_ob.id;
      v_remaining := v_remaining - v_ob.amount;
      v_closed := v_closed + 1;
    end if;
  end loop;

  -- si todos los items del batch están pagados → finalized
  if not exists (select 1 from public.settlement_items
                 where settlement_batch_id = v_batch.id and status = 'pending') then
    update public.settlement_batches set status = 'finalized', finalized_at = now() where id = v_batch.id;
  end if;

  perform public._emit_activity(v_batch.context_actor_id, v_caller, 'money.settlement_paid', 'settlement_item', p_settlement_item_id,
    jsonb_build_object('amount', v_item.amount, 'obligations_closed', v_closed));

  return jsonb_build_object('item_id', p_settlement_item_id, 'transaction_id', v_txn, 'obligations_closed', v_closed);
end; $$;

revoke all on function public.mark_settlement_paid(uuid) from public, anon;
grant execute on function public.mark_settlement_paid(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.money_transactions enable row level security;
alter table public.money_splits enable row level security;
alter table public.settlement_batches enable row level security;
alter table public.settlement_items enable row level security;

create policy txn_select on public.money_transactions
  for select to authenticated
  using (
    from_actor_id = public.current_actor_id() or to_actor_id = public.current_actor_id()
    or created_by_actor_id = public.current_actor_id()
    or (context_actor_id is not null and public.is_context_member(context_actor_id))
  );

create policy splits_select on public.money_splits
  for select to authenticated
  using (
    actor_id = public.current_actor_id()
    or exists (select 1 from public.money_transactions t
               where t.id = money_splits.transaction_id
                 and t.context_actor_id is not null and public.is_context_member(t.context_actor_id))
  );

create policy batches_select on public.settlement_batches
  for select to authenticated
  using (context_actor_id is not null and public.is_context_member(context_actor_id));

create policy items_select on public.settlement_items
  for select to authenticated
  using (
    from_actor_id = public.current_actor_id() or to_actor_id = public.current_actor_id()
    or exists (select 1 from public.settlement_batches b
               where b.id = settlement_items.settlement_batch_id
                 and b.context_actor_id is not null and public.is_context_member(b.context_actor_id))
  );

revoke all on public.money_transactions, public.money_splits,
       public.settlement_batches, public.settlement_items from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m9_money()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_auth_c uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_c uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_batch uuid; v_item uuid;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M9A', '+520000000019', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M9B', '+520000000020', null);
  v_c := public._create_person_actor_for_auth_user(v_auth_c, 'Smoke M9C', '+520000000021', null);

  -- Setup: contexto con 3 miembros
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m9 Cena', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Caso 1: A paga $900 de cena, split entre 3 → B y C deben $300 c/u a A
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 900, 'MXN', '_smoke_m9 Cena sushi');
  if (v_result->>'share_per_person')::numeric <> 300 then
    raise exception 'mvp2_m9 Caso1: split incorrecto (%)', v_result->>'share_per_person';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and obligation_type = 'expense_share'
        and creditor_actor_id = v_a and amount = 300) <> 2 then
    raise exception 'mvp2_m9 Caso1: obligations de split incorrectas';
  end if;

  -- Caso 2: B registra resultado de juego — B ganó 200, C perdió 200
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.record_game_result(v_ctx::uuid,
    jsonb_build_array(
      jsonb_build_object('actor_id', v_b, 'amount', 200),
      jsonb_build_object('actor_id', v_c, 'amount', -200)));
  if jsonb_array_length(v_result->'obligations') <> 1 then
    raise exception 'mvp2_m9 Caso2: game_debt no creada';
  end if;

  -- Caso 3: generate_settlement_batch (admin) — neteo greedy
  -- Estado: B debe 300 a A; C debe 300 a A + 200 a B
  -- Neto: A +600, B -100 (debe 300, le deben 200), C -500
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'mvp2_m9 Caso3: batch no generado'; end if;
  -- el neteo correcto: C paga 500 (a A), B paga 100 (a A) — exactamente 2 transferencias
  if jsonb_array_length(v_result->'items') <> 2 then
    raise exception 'mvp2_m9 Caso3: settlement no optimizado (% items)', jsonb_array_length(v_result->'items');
  end if;
  -- total a recibir por A = 600
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'to')::uuid = v_a) <> 600 then
    raise exception 'mvp2_m9 Caso3: neteo incorrecto para A';
  end if;

  -- Caso 4: member sin money.settle NO puede generar batch
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare v_caught boolean := false;
  begin
    begin
      perform public.generate_settlement_batch(v_ctx::uuid, 'MXN');
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m9 Caso4: member genero batch sin autoridad'; end if;
  end;

  -- Caso 5: mark_settlement_paid por el deudor → transaction + obligations cerradas
  select id into v_item from public.settlement_items
   where settlement_batch_id = v_batch and from_actor_id = v_c limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  v_result := public.mark_settlement_paid(v_item);
  if (v_result->>'transaction_id') is null then
    raise exception 'mvp2_m9 Caso5: settlement payment no creó transaction';
  end if;
  -- idempotente
  v_result := public.mark_settlement_paid(v_item);
  if not (v_result->>'already_paid')::boolean then
    raise exception 'mvp2_m9 Caso5: mark_settlement_paid no es idempotente';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.settlement_items where settlement_batch_id in
    (select id from public.settlement_batches where context_actor_id = v_ctx::uuid);
  delete from public.settlement_batches where context_actor_id = v_ctx::uuid;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx::uuid);
  delete from public.money_transactions where context_actor_id = v_ctx::uuid;
  delete from public.obligations where context_actor_id = v_ctx::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b, v_c);
  delete from public.actors where id in (v_a, v_b, v_c);
  delete from auth.users where id in (v_auth_a, v_auth_b, v_auth_c);

  raise notice '_smoke_mvp2_m9_money passed (5 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m9_money() from public, anon, authenticated;

comment on function public._smoke_mvp2_m9_money() is 'Smoke MVP2 M.9: expense split, game debts, settlement greedy min-cashflow, pago.';
