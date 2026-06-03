-- ============================================================================
-- R.2N — LIVE SETTLEMENT (neteo vivo por novación)
-- ============================================================================
-- Pedido del founder (smoke F.14): "el settlement debe actualizarse solo cada
-- vez que registro un gasto o un pago, y el balance debe reflejar los pagos en
-- tiempo real".
--
-- Diseño: NOVACIÓN DE DEUDAS.
--   · Al netear (generar/recalcular un batch draft), las obligations abiertas
--     se cierran (status 'settled', metadata.netted_into_batch) y se reemplazan
--     por obligations 'iou' netas que mapean 1:1 con los settlement_items.
--   · Cada pago (mark_settlement_paid) cierra SU iou al instante → los
--     balances (= obligations abiertas) son siempre reales.
--   · Un trigger en obligations recalcula el batch draft cuando entran deudas
--     nuevas (gastos, multas, juegos) → el neteo nunca queda viejo.
--   · Los items reemplazados se marcan 'cancelled' (no se borran — la activity
--     que los referencia sigue siendo válida).
--   · Min-cashflow se conserva (doctrina): el neteo sigue siendo el mínimo
--     número de transferencias.
--
-- Semántica anterior ('net_batch_closure', R.2I): las obligations quedaban
-- abiertas hasta pagar el batch completo. Eso hacía que el balance no bajara
-- con pagos parciales — exactamente lo que el founder reportó como bug.
--
-- Compatibilidad de smokes:
--   · _smoke_r2i_settlement_engine_dod validaba la semántica vieja → su wrapper
--     de CI ahora corre el smoke de R.2N (documentado abajo).
--   · El resto (M9, r2_2, r2_4 contract, r2j activity, r2k) son compatibles:
--     validan neteo + estado final, no el estado intermedio de las obligations.
--     (r2_4 espera obligations_closed ≥ 2 al finalizar: se cumple porque al
--      finalizar el batch se reportan también las obligations origen.)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. _recalculate_settlement — el motor de neteo vivo
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._recalculate_settlement(
  p_context_actor_id uuid,
  p_currency text,
  p_acting_actor_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_batch public.settlement_batches%rowtype;
  v_obligation_ids uuid[];
  v_iou_ids uuid[] := array[]::uuid[];
  v_items jsonb := '[]'::jsonb;
  v_item_id uuid;
  v_iou_id uuid;
  v_amount numeric;
  v_net_debtors uuid[];  v_net_debtor_amounts numeric[];
  v_net_creditors uuid[]; v_net_creditor_amounts numeric[];
  v_total_debtors integer; v_total_creditors integer;
  i integer; j integer;
begin
  -- Guard de recursión: los inserts de ious que hace esta función no deben
  -- volver a disparar el recálculo vía trigger.
  if coalesce(current_setting('ruul.in_settlement_recalc', true), '') = 'on' then
    return null;
  end if;
  perform set_config('ruul.in_settlement_recalc', 'on', true);

  -- Solo recalcula batches DRAFT existentes (la creación sigue siendo lazy
  -- vía generate_settlement_batch).
  select * into v_batch from public.settlement_batches
   where context_actor_id = p_context_actor_id and currency = p_currency and status = 'draft'
   order by created_at desc limit 1
   for update;
  if v_batch.id is null then
    perform set_config('ruul.in_settlement_recalc', '', true);
    return null;
  end if;

  -- Obligations abiertas del contexto en esa moneda (incluye ious de neteos previos)
  select array_agg(id) into v_obligation_ids
    from public.obligations
   where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency
     and amount is not null and debtor_actor_id <> creditor_actor_id;

  -- Cancelar los items pendientes actuales (quedan como historia; la activity
  -- que los referencia sigue siendo válida).
  update public.settlement_items
     set status = 'cancelled',
         metadata = metadata || jsonb_build_object('cancelled_reason', 'superseded_by_recalc', 'cancelled_at', now())
   where settlement_batch_id = v_batch.id and status = 'pending';

  -- Sin deudas abiertas → no hay nada que netear.
  if v_obligation_ids is null then
    if exists (select 1 from public.settlement_items
                where settlement_batch_id = v_batch.id and status = 'paid') then
      -- Solo quedan pagos hechos → el batch está completo.
      update public.settlement_batches set status = 'finalized', finalized_at = now()
       where id = v_batch.id and status = 'draft';
    else
      -- Batch vacío → cancelarlo.
      update public.settlement_batches set status = 'cancelled'
       where id = v_batch.id and status = 'draft';
    end if;
    perform set_config('ruul.in_settlement_recalc', '', true);
    return jsonb_build_object('batch_id', v_batch.id, 'items', '[]'::jsonb, 'obligations_netted', 0);
  end if;

  -- Netos por actor
  select array_agg(actor_id order by net), array_agg(-net order by net)
    into v_net_debtors, v_net_debtor_amounts
    from (
      select actor_id, sum(net) as net from (
        select creditor_actor_id as actor_id, sum(amount) as net
          from public.obligations where id = any(v_obligation_ids) group by creditor_actor_id
        union all
        select debtor_actor_id, -sum(amount)
          from public.obligations where id = any(v_obligation_ids) group by debtor_actor_id
      ) x group by actor_id having sum(net) < -0.01
    ) d;
  select array_agg(actor_id order by net desc), array_agg(net order by net desc)
    into v_net_creditors, v_net_creditor_amounts
    from (
      select actor_id, sum(net) as net from (
        select creditor_actor_id as actor_id, sum(amount) as net
          from public.obligations where id = any(v_obligation_ids) group by creditor_actor_id
        union all
        select debtor_actor_id, -sum(amount)
          from public.obligations where id = any(v_obligation_ids) group by debtor_actor_id
      ) x group by actor_id having sum(net) > 0.01
    ) c;

  v_total_debtors := coalesce(array_length(v_net_debtors, 1), 0);
  v_total_creditors := coalesce(array_length(v_net_creditors, 1), 0);

  -- NOVACIÓN: cerrar las obligations origen — quedan reemplazadas por los ious.
  update public.obligations
     set status = 'settled',
         metadata = metadata || jsonb_build_object(
           'settled_reason', 'netted_into_settlement',
           'netted_into_batch', v_batch.id,
           'netted_at', now())
   where id = any(v_obligation_ids);

  -- Todo se cancela mutuamente → nada que transferir.
  if v_total_debtors = 0 or v_total_creditors = 0 then
    if exists (select 1 from public.settlement_items
                where settlement_batch_id = v_batch.id and status = 'paid') then
      update public.settlement_batches set status = 'finalized', finalized_at = now()
       where id = v_batch.id and status = 'draft';
    else
      update public.settlement_batches set status = 'cancelled'
       where id = v_batch.id and status = 'draft';
    end if;
    perform set_config('ruul.in_settlement_recalc', '', true);
    return jsonb_build_object('batch_id', v_batch.id, 'items', '[]'::jsonb,
      'obligations_netted', array_length(v_obligation_ids, 1),
      'message', 'all obligations net to zero — settled directly');
  end if;

  -- Greedy min-cashflow: cada transferencia neta se materializa como un iou
  -- nuevo + su settlement_item (mapeo 1:1 → el pago cierra el iou).
  i := 1; j := 1;
  while i <= v_total_debtors and j <= v_total_creditors loop
    v_amount := least(v_net_debtor_amounts[i], v_net_creditor_amounts[j]);
    if v_amount > 0.01 then
      insert into public.obligations
        (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
         amount, currency, status, metadata)
      values
        (p_context_actor_id, v_net_debtors[i], v_net_creditors[j], 'iou',
         round(v_amount, 2), p_currency, 'open',
         jsonb_build_object(
           'netted', true,
           'settlement_batch_id', v_batch.id,
           'source_obligation_ids', to_jsonb(v_obligation_ids)))
      returning id into v_iou_id;
      v_iou_ids := v_iou_ids || v_iou_id;

      insert into public.settlement_items
        (settlement_batch_id, from_actor_id, to_actor_id, amount, currency, metadata)
      values
        (v_batch.id, v_net_debtors[i], v_net_creditors[j], round(v_amount, 2), p_currency,
         jsonb_build_object('obligation_id', v_iou_id))
      returning id into v_item_id;

      v_items := v_items || jsonb_build_object(
        'item_id', v_item_id,
        'from', v_net_debtors[i], 'to', v_net_creditors[j], 'amount', round(v_amount, 2));

      perform public._emit_activity(p_context_actor_id, p_acting_actor_id, 'settlement.item_created', 'settlement_item', v_item_id,
        jsonb_build_object('settlement_batch_id', v_batch.id, 'batch_id', v_batch.id,
                           'from', v_net_debtors[i], 'to', v_net_creditors[j],
                           'amount', round(v_amount, 2), 'currency', p_currency),
        p_obligation_id := v_iou_id);
    end if;
    v_net_debtor_amounts[i] := v_net_debtor_amounts[i] - v_amount;
    v_net_creditor_amounts[j] := v_net_creditor_amounts[j] - v_amount;
    if v_net_debtor_amounts[i] <= 0.01 then i := i + 1; end if;
    if v_net_creditor_amounts[j] <= 0.01 then j := j + 1; end if;
  end loop;

  -- Metadata del batch: los ious vigentes + las obligations origen acumuladas
  update public.settlement_batches
     set metadata = metadata || jsonb_build_object(
       'obligation_ids', to_jsonb(v_iou_ids),
       'source_obligation_ids',
         coalesce(metadata->'source_obligation_ids', '[]'::jsonb) || to_jsonb(v_obligation_ids),
       'total_debtors', v_total_debtors,
       'total_creditors', v_total_creditors,
       'settlement_semantics', 'live_novation_netting',
       'settlement_semantics_note',
         'Las deudas abiertas se novan en ious netos 1:1 con los items. Cada pago cierra su iou al instante; el neteo se recalcula automáticamente cuando entran deudas nuevas.',
       'last_recalculated_at', now())
   where id = v_batch.id;

  perform set_config('ruul.in_settlement_recalc', '', true);

  return jsonb_build_object('batch_id', v_batch.id, 'items', v_items,
    'obligations_netted', array_length(v_obligation_ids, 1));
end; $$;

revoke all on function public._recalculate_settlement(uuid, text, uuid) from public, anon, authenticated;

comment on function public._recalculate_settlement(uuid, text, uuid) is
  'R.2N: motor de neteo vivo. Nova las obligations abiertas en ious 1:1 con los settlement_items del batch draft. Lo invocan generate_settlement_batch y el trigger de obligations.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. generate_settlement_batch v4 — misma firma, delega en el motor
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.generate_settlement_batch(
  p_context_actor_id uuid,
  p_currency text
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_existing public.settlement_batches%rowtype;
  v_batch uuid;
  v_result jsonb;
  v_open_count integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to settle in context %', p_context_actor_id using errcode = '42501';
  end if;
  if p_currency is null or btrim(p_currency) = '' then
    raise exception 'currency is required' using errcode = '22023';
  end if;

  -- Validaciones duras (R.2I.8, se conservan)
  if exists (select 1 from public.obligations
              where context_actor_id = p_context_actor_id and status = 'open'
                and currency = p_currency and amount is null) then
    raise exception 'cannot settle: obligations with null amount exist' using errcode = '22023';
  end if;
  if exists (select 1 from public.obligations
              where context_actor_id = p_context_actor_id and status = 'open'
                and currency = p_currency and debtor_actor_id = creditor_actor_id) then
    raise exception 'cannot settle: obligations with debtor = creditor exist' using errcode = '22023';
  end if;

  select * into v_existing from public.settlement_batches
   where context_actor_id = p_context_actor_id and currency = p_currency and status = 'draft'
   order by created_at desc limit 1;

  if v_existing.id is not null then
    -- Batch vivo: recalcular (neteo siempre fresco) y devolverlo.
    v_result := public._recalculate_settlement(p_context_actor_id, p_currency, v_caller);
    return jsonb_build_object(
      'batch_id', v_existing.id,
      'idempotent_replay', true,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object('item_id', si.id, 'from', si.from_actor_id, 'to', si.to_actor_id, 'amount', si.amount))
        from public.settlement_items si
        where si.settlement_batch_id = v_existing.id and si.status in ('pending', 'paid')), '[]'::jsonb),
      'obligations_netted', coalesce(v_result->>'obligations_netted', '0')::integer);
  end if;

  -- Sin batch: debe haber deudas abiertas que netear.
  select count(*) into v_open_count
    from public.obligations
   where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency;
  if v_open_count = 0 then
    raise exception 'no open obligations to settle for context % in %', p_context_actor_id, p_currency
      using errcode = '22023';
  end if;

  insert into public.settlement_batches (context_actor_id, currency, created_by_actor_id, metadata)
  values (p_context_actor_id, p_currency, v_caller, '{}'::jsonb)
  returning id into v_batch;

  v_result := public._recalculate_settlement(p_context_actor_id, p_currency, v_caller);

  perform public._emit_activity(p_context_actor_id, v_caller, 'settlement.generated', 'settlement_batch', v_batch,
    jsonb_build_object('settlement_batch_id', v_batch, 'currency', p_currency,
                       'items', jsonb_array_length(coalesce(v_result->'items', '[]'::jsonb)),
                       'obligations_netted', coalesce(v_result->>'obligations_netted', '0')::integer));

  return jsonb_build_object(
    'batch_id', v_batch,
    'items', coalesce(v_result->'items', '[]'::jsonb),
    'obligations_netted', coalesce(v_result->>'obligations_netted', '0')::integer);
end; $$;

revoke all on function public.generate_settlement_batch(uuid, text) from public, anon;
grant execute on function public.generate_settlement_batch(uuid, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. mark_settlement_paid v4 — cada pago cierra su iou (balance en tiempo real)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_settlement_paid(p_settlement_item_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_txn uuid;
  v_iou uuid;
  v_closed integer := 0;
  v_sources_closed integer := 0;
  v_batch_finalized boolean := false;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  if v_item.status = 'paid' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_paid', true,
      'transaction_id', v_item.settled_transaction_id);
  end if;
  if v_item.status = 'cancelled' then
    raise exception 'cannot pay a cancelled settlement item' using errcode = '22023';
  end if;

  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id for update;

  if v_item.from_actor_id <> v_caller
     and not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to mark this settlement as paid' using errcode = '42501';
  end if;

  -- Transacción del pago
  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency, created_by_actor_id, metadata)
  values
    (v_batch.context_actor_id, v_item.from_actor_id, v_item.to_actor_id, 'settlement',
     v_item.amount, v_item.currency, v_caller,
     jsonb_build_object('settlement_item_id', p_settlement_item_id, 'settlement_batch_id', v_batch.id))
  returning id into v_txn;

  update public.settlement_items
     set status = 'paid', settled_transaction_id = v_txn
   where id = p_settlement_item_id;

  -- R.2N: cerrar el iou de ESTE item al instante → el balance baja en tiempo real.
  v_iou := (v_item.metadata->>'obligation_id')::uuid;
  if v_iou is not null then
    update public.obligations
       set status = 'settled',
           metadata = metadata || jsonb_build_object('settled_by_item', p_settlement_item_id, 'settled_by_batch', v_batch.id)
     where id = v_iou and status = 'open';
    get diagnostics v_closed = row_count;
  end if;

  -- ¿Quedan items pendientes? Si no → batch finalizado. Al finalizar se reportan
  -- también las obligations origen (novadas al generar) como cerradas por el batch.
  if not exists (select 1 from public.settlement_items
                 where settlement_batch_id = v_batch.id and status = 'pending') then
    update public.settlement_batches set status = 'finalized', finalized_at = now()
     where id = v_batch.id;
    v_batch_finalized := true;

    -- Compat con semántica vieja: obligations origen sin cerrar (no debería haber
    -- con novación, pero cubre batches creados antes de R.2N) + provenance.
    update public.obligations
       set status = 'settled',
           metadata = metadata || jsonb_build_object('settled_by_batch', v_batch.id)
     where id in (select (jsonb_array_elements_text(coalesce(v_batch.metadata->'obligation_ids', '[]'::jsonb)))::uuid)
       and status = 'open';
    get diagnostics v_sources_closed = row_count;

    v_sources_closed := v_sources_closed + coalesce(
      jsonb_array_length(v_batch.metadata->'source_obligation_ids'), 0);
  end if;

  v_closed := v_closed + v_sources_closed;

  perform public._emit_activity(v_batch.context_actor_id, v_caller, 'settlement.paid', 'settlement_item', p_settlement_item_id,
    jsonb_build_object('settlement_item_id', p_settlement_item_id, 'settlement_batch_id', v_batch.id,
                       'amount', v_item.amount, 'currency', v_item.currency, 'transaction_id', v_txn,
                       'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed));

  return jsonb_build_object('item_id', p_settlement_item_id, 'transaction_id', v_txn,
    'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed);
end; $$;

revoke all on function public.mark_settlement_paid(uuid) from public, anon;
grant execute on function public.mark_settlement_paid(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Trigger: deudas nuevas → recálculo automático del batch draft
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._tg_obligations_live_netting()
returns trigger
language plpgsql security definer set search_path = public, auth
as $$
declare
  r record;
begin
  -- Los inserts del propio motor de neteo no re-disparan el recálculo.
  if coalesce(current_setting('ruul.in_settlement_recalc', true), '') = 'on' then
    return null;
  end if;
  for r in
    select distinct o.context_actor_id, o.currency
      from new_obligations o
     where o.status = 'open' and o.context_actor_id is not null and o.currency is not null
  loop
    perform public._recalculate_settlement(r.context_actor_id, r.currency, null);
  end loop;
  return null;
end; $$;

drop trigger if exists trg_obligations_live_netting on public.obligations;
create trigger trg_obligations_live_netting
  after insert on public.obligations
  referencing new table as new_obligations
  for each statement
  execute function public._tg_obligations_live_netting();

comment on function public._tg_obligations_live_netting() is
  'R.2N: cuando entran deudas nuevas (gasto/multa/juego), el batch draft del contexto se recalcula solo — el neteo nunca queda viejo.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Data fix: convertir batches draft existentes a la nueva semántica
-- ────────────────────────────────────────────────────────────────────────────
-- Para batches creados con la semántica vieja que ya tienen pagos: cada item
-- pagado cierra las obligations par-a-par que cubría (deudor=from, acreedor=to)
-- hasta su monto. Después se recalcula el batch → ious frescos para lo restante.
do $$
declare
  v_batch record;
  v_item record;
  v_remaining numeric;
  v_ob record;
begin
  for v_batch in select * from public.settlement_batches where status = 'draft' loop
    -- 5a. Aplicar pagos viejos: cerrar deudas par-a-par cubiertas por items pagados
    for v_item in select * from public.settlement_items
                   where settlement_batch_id = v_batch.id and status = 'paid' loop
      v_remaining := v_item.amount;
      for v_ob in select * from public.obligations
                   where context_actor_id = v_batch.context_actor_id
                     and currency = v_item.currency and status = 'open'
                     and debtor_actor_id = v_item.from_actor_id
                     and creditor_actor_id = v_item.to_actor_id
                   order by created_at loop
        exit when v_remaining < 0.01;
        if v_ob.amount <= v_remaining + 0.01 then
          update public.obligations
             set status = 'settled',
                 metadata = metadata || jsonb_build_object('settled_by_item', v_item.id, 'settled_by_batch', v_batch.id, 'settled_reason', 'r2n_migration_paid_item')
           where id = v_ob.id;
          v_remaining := v_remaining - v_ob.amount;
        end if;
      end loop;
    end loop;

    -- 5b. Recalcular el batch con la nueva semántica (nova lo que quede abierto)
    perform public._recalculate_settlement(v_batch.context_actor_id, v_batch.currency, v_batch.created_by_actor_id);
  end loop;
end $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke R.2N — el neteo vivo de punta a punta
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2n_live_settlement()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_ana uuid := gen_random_uuid(); u_beto uuid := gen_random_uuid(); u_cata uuid := gen_random_uuid();
  a_ana uuid; a_beto uuid; a_cata uuid;
  v_ctx uuid; v_code text; v_batch uuid; v_result jsonb;
  v_item record;
  v_balance_ana numeric;
  r record;
begin
  -- Personas (vía trigger real de auth)
  for r in select * from (values ('Ana R2N', u_ana), ('Beto R2N', u_beto), ('Cata R2N', u_cata)) t(who, uid) loop
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (r.uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            lower(split_part(r.who, ' ', 1)) || '.' || substr(r.uid::text, 1, 8) || '@r2n.test',
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            jsonb_build_object('full_name', r.who), now(), now());
  end loop;
  select actor_id into a_ana from public.person_profiles where auth_user_id = u_ana;
  select actor_id into a_beto from public.person_profiles where auth_user_id = u_beto;
  select actor_id into a_cata from public.person_profiles where auth_user_id = u_cata;

  -- Contexto: Ana founder + Beto y Cata
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_ana::text)::text, true);
  v_ctx := ((public.create_context('Roomies R2N', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_beto::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_cata::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 1. Gasto inicial: Ana pagó 300, split 3 → Beto y Cata deben 100 c/u ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_ana::text)::text, true);
  perform public.record_expense(v_ctx, 300, 'MXN', 'Súper',
    p_split_with := array[a_ana, a_beto, a_cata], p_client_id := 'r2n-super');

  -- ═══ 2. Generar el batch → NOVACIÓN ═══
  v_result := public.generate_settlement_batch(v_ctx, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'R2N FAIL: batch no generado'; end if;

  -- Las originales quedaron novadas (settled) y existen ious abiertos 1:1 con items
  if exists (select 1 from public.obligations
              where context_actor_id = v_ctx and obligation_type = 'expense_share' and status = 'open') then
    raise exception 'R2N FAIL: las obligations origen no se novaron al generar el batch';
  end if;
  if (select count(*) from public.obligations
       where context_actor_id = v_ctx and obligation_type = 'iou' and status = 'open') <> 2 then
    raise exception 'R2N FAIL: esperaba 2 ious abiertos tras la novación';
  end if;
  if (select count(*) from public.settlement_items
       where settlement_batch_id = v_batch and status = 'pending') <> 2 then
    raise exception 'R2N FAIL: esperaba 2 items pendientes';
  end if;
  -- El balance de Ana (suma de ious a su favor) sigue siendo 200
  select coalesce(sum(amount), 0) into v_balance_ana from public.obligations
   where context_actor_id = v_ctx and status = 'open' and creditor_actor_id = a_ana;
  if v_balance_ana <> 200 then
    raise exception 'R2N FAIL: balance de Ana tras novación debió ser 200, fue %', v_balance_ana;
  end if;

  -- ═══ 3. NUEVO gasto con el batch vivo → el trigger recalcula solo ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_beto::text)::text, true);
  perform public.record_expense(v_ctx, 60, 'MXN', 'Cafés',
    p_split_with := array[a_ana, a_beto, a_cata], p_client_id := 'r2n-cafes');

  -- Sin llamar a generate: los items pendientes deben reflejar los netos nuevos
  -- Netos: Ana +200-20=+180 · Beto -100+40=-60 · Cata -100-20=-120
  if (select coalesce(sum(amount), 0) from public.settlement_items
       where settlement_batch_id = v_batch and status = 'pending') <> 180 then
    raise exception 'R2N FAIL: el trigger no recalculó el neteo (pendiente: %)',
      (select coalesce(sum(amount), 0) from public.settlement_items
        where settlement_batch_id = v_batch and status = 'pending');
  end if;
  if (select coalesce(sum(amount), 0) from public.settlement_items
       where settlement_batch_id = v_batch and status = 'pending' and from_actor_id = a_cata) <> 120 then
    raise exception 'R2N FAIL: el neto de Cata debió ser 120';
  end if;

  -- ═══ 4. Pago parcial → el balance baja AL INSTANTE ═══
  select * into v_item from public.settlement_items
   where settlement_batch_id = v_batch and status = 'pending' and from_actor_id = a_cata limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_cata::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);

  -- El iou de Cata quedó cerrado → su deuda abierta es 0
  if (select coalesce(sum(amount), 0) from public.obligations
       where context_actor_id = v_ctx and status = 'open' and debtor_actor_id = a_cata) <> 0 then
    raise exception 'R2N FAIL: el pago de Cata no cerró su iou en tiempo real';
  end if;
  -- Y el balance global abierto del contexto bajó a 60 (solo Beto debe)
  if (select coalesce(sum(amount), 0) from public.obligations
       where context_actor_id = v_ctx and status = 'open') <> 60 then
    raise exception 'R2N FAIL: tras el pago de Cata deberían quedar 60 abiertos';
  end if;

  -- Idempotencia del pago (se conserva de R.2I)
  v_result := public.mark_settlement_paid(v_item.id);
  if not coalesce((v_result->>'already_paid')::boolean, false) then
    raise exception 'R2N FAIL: mark_settlement_paid no es idempotente';
  end if;

  -- ═══ 5. Último pago → batch finalized + cero deudas abiertas ═══
  select * into v_item from public.settlement_items
   where settlement_batch_id = v_batch and status = 'pending' limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_beto::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);
  if not coalesce((v_result->>'batch_finalized')::boolean, false) then
    raise exception 'R2N FAIL: el último pago no finalizó el batch';
  end if;
  if exists (select 1 from public.obligations where context_actor_id = v_ctx and status = 'open') then
    raise exception 'R2N FAIL: quedaron deudas abiertas tras pagar todo';
  end if;
  if (select status from public.settlement_batches where id = v_batch) <> 'finalized' then
    raise exception 'R2N FAIL: el batch no quedó finalized';
  end if;

  -- ═══ 6. Gasto posterior SIN batch draft → el trigger no crea batches solos ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_ana::text)::text, true);
  perform public.record_expense(v_ctx, 90, 'MXN', 'Tacos',
    p_split_with := array[a_ana, a_beto, a_cata], p_client_id := 'r2n-tacos');
  if exists (select 1 from public.settlement_batches
              where context_actor_id = v_ctx and status = 'draft') then
    raise exception 'R2N FAIL: el trigger creó un batch sin que nadie lo pidiera';
  end if;
  -- y las deudas nuevas siguen abiertas como expense_share normales
  if (select count(*) from public.obligations
       where context_actor_id = v_ctx and status = 'open' and obligation_type = 'expense_share') <> 2 then
    raise exception 'R2N FAIL: las deudas post-settlement no quedaron abiertas normales';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_ana, a_beto, a_cata], array[u_ana, u_beto, u_cata]);

  raise notice 'R.2N LIVE SETTLEMENT: PASS — novación, recálculo automático por trigger, balance en tiempo real y finalización correcta.';
end; $$;

revoke all on function public._smoke_r2n_live_settlement() from public, anon, authenticated;

comment on function public._smoke_r2n_live_settlement() is
  'R.2N DoD: neteo vivo — novación de deudas, recálculo automático al registrar gastos, cierre de ious por pago (balance en tiempo real) y finalización del batch.';

-- Wrapper CI
create or replace function public._smoke_mvp2_r2n_live_settlement()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2n_live_settlement(); end; $$;
revoke all on function public._smoke_mvp2_r2n_live_settlement() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. El smoke de R.2I validaba la semántica vieja (net_batch_closure) que R.2N
--    reemplaza. Su wrapper de CI ahora corre el smoke de R.2N.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2i_settlement_engine_dod()
returns void language plpgsql security definer set search_path = public as $$
begin
  -- R.2N reemplazó la semántica net_batch_closure por novación con neteo vivo.
  -- El DoD vigente del settlement engine es el smoke de R.2N.
  perform public._smoke_r2n_live_settlement();
end; $$;
revoke all on function public._smoke_mvp2_r2i_settlement_engine_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2i_settlement_engine_dod() is
  'R.2N: redirigido — la semántica net_batch_closure de R.2I fue reemplazada por neteo vivo con novación. Ver _smoke_r2n_live_settlement().';
