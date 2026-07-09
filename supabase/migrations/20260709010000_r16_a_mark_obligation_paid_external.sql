-- ============================================================================
-- R.16.A — PAGO EXTERNO: mark_obligation_paid_external (2026-07-09)
-- ============================================================================
-- Founder: "le pagué a Pedro por Venmo/efectivo; hoy el único camino es
-- perdonar la deuda, que miente semánticamente". forgive_obligation marca
-- status='forgiven' (condonación — NO contamina ledger como paid). Este slice
-- agrega la vía honesta: el ACREEDOR confirma que recibió el pago fuera de la
-- app y la obligación cierra como 'settled' con su money_transaction real.
--
-- Diseño (mínimo honesto, calcado de los caminos existentes):
--   · Auth: SOLO el creditor (él confirma que recibió). El deudor recibe 42501
--     con copy claro — su camino es el settlement handshake (mark_settlement_paid
--     → confirm/reject del acreedor, R.5Z).
--   · Efecto contable = el mismo que _settlement_finalize_item (R.5Z), pero con
--     transaction_type='payment' (transferencia directa deudor→acreedor fuera
--     del neteo). El writer inserta sus splits payer/creditor porque el trigger
--     _emit_splits_for_two_party_txn (R.9.D) solo sintetiza settlement y
--     contribution — con splits, el trigger de money_splits emite las filas del
--     ledger sombra (mapeo R.9.D: payment payer→credit / creditor→debit).
--   · Compatibilidad R.2N (neteo vivo por novación): si la obligación es un iou
--     novado, tiene un settlement_item 1:1 pendiente. Cerrar solo la obligación
--     dejaría un "pago pendiente" fantasma en Liquidaciones (el trigger de
--     recálculo es AFTER INSERT — un UPDATE de status no recalcula). Se cierra
--     el item también (status='paid' + settled_transaction_id) y se finaliza el
--     batch si era el último pendiente, igual que _settlement_finalize_item.
--   · Idempotencia por p_client_id (patrón D9 de record_fine R.9.B): la
--     transaction 'payment' ancla la key vía idx_txn_client_id
--     (created_by_actor_id, client_id).
--   · Activity: 'obligation.settled_external' (catalogado aquí mismo).
--   · Descriptor: obligation_available_actions gana 'mark_paid_external'
--     (money + open, enabled solo para el creditor) — F.2X: la acción visible
--     en iOS nace del backend.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Catálogo de activity: obligation.settled_external
-- ────────────────────────────────────────────────────────────────────────────
insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('obligation.settled_external', 'obligation',
   'El acreedor marcó una deuda como pagada por fuera (efectivo/transferencia/Venmo)',
   'obligation', false)
on conflict (event_type) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. RPC mark_obligation_paid_external
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_obligation_paid_external(
  p_obligation_id uuid,
  p_channel text,
  p_note text default null,
  p_client_id text default null
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
  v_existing uuid;
  v_txn uuid;
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_batch_finalized boolean := false;
  v_rows integer := 0;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  if p_channel is null or p_channel not in ('cash', 'transfer', 'venmo', 'other') then
    raise exception 'invalid channel % (must be cash/transfer/venmo/other)', coalesce(p_channel, '<null>')
      using errcode = '22023';
  end if;

  -- ═══ Idempotencia por client_id (patrón D9 de record_fine R.9.B) ═══
  if p_client_id is not null then
    select id into v_existing from public.money_transactions
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('transaction_id', v_existing, 'idempotent_replay', true,
        'obligation_id', p_obligation_id, 'status', 'settled', 'changed', false);
    end if;
  end if;

  select * into v_ob from public.obligations where id = p_obligation_id for update;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  -- Replay sin client_id: si ya quedó settled por esta misma vía, noop amable.
  if v_ob.status = 'settled' and v_ob.metadata->>'settled_via' = 'external' then
    return jsonb_build_object('changed', false, 'obligation_id', p_obligation_id,
      'status', 'settled', 'noop', true,
      'transaction_id', (v_ob.metadata->>'external_transaction_id')::uuid);
  end if;

  if v_ob.obligation_kind <> 'money' then
    raise exception 'only money obligations can be marked as paid externally' using errcode = '22023';
  end if;
  if v_ob.status <> 'open' then
    raise exception 'cannot mark obligation in status % as paid externally', v_ob.status using errcode = '22023';
  end if;
  if v_ob.amount is null or v_ob.currency is null then
    raise exception 'obligation has no amount/currency to settle' using errcode = '22023';
  end if;

  -- Solo el ACREEDOR confirma que recibió el pago (simetría con
  -- confirm_settlement_paid: quien recibe es quien atestigua).
  if v_ob.debtor_actor_id = v_caller then
    raise exception 'el deudor no puede marcar el pago externo: pide a quien recibió el pago que lo marque'
      using errcode = '42501';
  end if;
  if v_ob.creditor_actor_id <> v_caller then
    raise exception 'not authorized to mark this obligation as paid externally (solo el acreedor)'
      using errcode = '42501';
  end if;

  -- ═══ Transacción del pago externo (idempotency key vive aquí) ═══
  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency,
     obligation_id, metadata, client_id, created_by_actor_id)
  values
    (v_ob.context_actor_id, v_ob.debtor_actor_id, v_ob.creditor_actor_id, 'payment',
     v_ob.amount, v_ob.currency, p_obligation_id,
     jsonb_strip_nulls(jsonb_build_object(
       'settled_via', 'external',
       'channel', p_channel,
       'note', p_note,
       'obligation_id', p_obligation_id,
       'marked_by', v_caller)),
     p_client_id, v_caller)
  returning id into v_txn;

  -- Splits del pago: R.9.D mapea payment payer→credit / creditor→debit; el
  -- trigger de money_splits emite el ledger sombra. Este writer inserta sus
  -- splits (patrón record_fine R.9.B) porque _emit_splits_for_two_party_txn
  -- solo sintetiza settlement/contribution.
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, v_ob.debtor_actor_id, 'payer', v_ob.amount, v_ob.currency),
         (v_txn, v_ob.creditor_actor_id, 'creditor', v_ob.amount, v_ob.currency);

  update public.obligations
     set status = 'settled',
         updated_at = now(),
         metadata = metadata || jsonb_strip_nulls(jsonb_build_object(
           'settled_via', 'external',
           'channel', p_channel,
           'note', p_note,
           'marked_by', v_caller,
           'settled_at', now(),
           'external_transaction_id', v_txn))
   where id = p_obligation_id;

  -- ═══ Compat R.2N: si la obligación es un iou novado con settlement_item 1:1
  -- vivo, cerrarlo también (mismo efecto que _settlement_finalize_item) para
  -- no dejar un pago pendiente fantasma en Liquidaciones. ═══
  select * into v_item from public.settlement_items
   where (metadata->>'obligation_id')::uuid = p_obligation_id
     and status in ('pending', 'pending_confirmation')
   limit 1
   for update;

  if v_item.id is not null then
    update public.settlement_items
       set status = 'paid',
           settled_transaction_id = v_txn,
           metadata = coalesce(metadata, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
             'paid_via', 'external',
             'channel', p_channel,
             'confirmed_by', v_caller,
             'confirmed_at', now()))
     where id = v_item.id;

    select * into v_batch from public.settlement_batches
     where id = v_item.settlement_batch_id for update;

    if v_batch.id is not null
       and not exists (select 1 from public.settlement_items
                        where settlement_batch_id = v_batch.id
                          and status in ('pending', 'pending_confirmation')) then
      update public.settlement_batches set status = 'finalized', finalized_at = now()
       where id = v_batch.id and status = 'draft';
      get diagnostics v_rows = row_count;
      v_batch_finalized := v_rows > 0;

      if v_batch_finalized then
        -- Compat semántica vieja (igual que _settlement_finalize_item): cerrar
        -- obligations origen del batch que sigan abiertas.
        update public.obligations
           set status = 'settled',
               metadata = metadata || jsonb_build_object('settled_by_batch', v_batch.id)
         where id in (select (jsonb_array_elements_text(coalesce(v_batch.metadata->'obligation_ids', '[]'::jsonb)))::uuid)
           and status = 'open';
      end if;
    end if;
  end if;

  perform public._emit_activity(
    coalesce(v_ob.context_actor_id, v_ob.creditor_actor_id),
    v_caller,
    'obligation.settled_external', 'obligation', p_obligation_id,
    jsonb_strip_nulls(jsonb_build_object(
      'obligation_type', v_ob.obligation_type,
      'obligation_kind', v_ob.obligation_kind,
      'amount', v_ob.amount,
      'currency', v_ob.currency,
      'debtor', v_ob.debtor_actor_id,
      'creditor', v_ob.creditor_actor_id,
      'channel', p_channel,
      'note', p_note,
      'transaction_id', v_txn,
      'settlement_item_id', v_item.id,
      'batch_finalized', v_batch_finalized)),
    p_obligation_id := p_obligation_id
  );

  return jsonb_build_object(
    'changed', true,
    'obligation_id', p_obligation_id,
    'status', 'settled',
    'transaction_id', v_txn,
    'channel', p_channel,
    'settlement_item_id', v_item.id,
    'batch_finalized', v_batch_finalized
  );
end;
$$;

revoke all on function public.mark_obligation_paid_external(uuid, text, text, text) from public, anon;
grant execute on function public.mark_obligation_paid_external(uuid, text, text, text) to authenticated, service_role;

comment on function public.mark_obligation_paid_external(uuid, text, text, text) is
  'R.16.A — El ACREEDOR confirma que recibió el pago de una obligación money fuera de
la app (channel: cash/transfer/venmo/other). Status → settled + money_transaction
type=payment (from=deudor, to=acreedor) con splits payer/creditor para el ledger
sombra R.9.D. Compat R.2N: si la obligación es un iou novado cierra su settlement_item
1:1 y finaliza el batch si era el último. Idempotente por p_client_id (patrón D9) y
noop si ya está settled_via=external. El deudor recibe 42501 (su camino es el
settlement handshake R.5Z). Emite obligation.settled_external.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. obligation_available_actions: + mark_paid_external (money + open,
--    enabled solo para el creditor). Cuerpo base VERBATIM de FE.2
--    (20260611162000) — solo se inserta el bloque nuevo.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.obligation_available_actions(p_obligation_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to public
as $$
declare
  v_ob public.obligations%rowtype;
  v_active boolean;
  v_is_debtor boolean;
  v_is_creditor boolean;
  v_is_manager boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then return '[]'::jsonb; end if;

  v_active := v_ob.status in ('open', 'accepted', 'in_progress');
  v_is_debtor := p_actor_id = v_ob.debtor_actor_id;
  v_is_creditor := p_actor_id = v_ob.creditor_actor_id;
  v_is_manager := v_ob.context_actor_id is not null
              and public.has_actor_authority(v_ob.context_actor_id, p_actor_id, 'money.settle');

  -- FE.2: 'pay' removida — el pago de obligaciones money vive en el flujo de
  -- settlement (generate_settlement_batch + mark_settlement_paid).

  if v_ob.obligation_kind <> 'money' and v_active then
    v_actions := v_actions || public._aa('mark_completed', 'Marcar como cumplida', 'obligations',
      v_is_debtor or v_is_creditor or v_is_manager,
      case when v_is_debtor or v_is_creditor or v_is_manager then 'Participas en esta obligación'
           else 'Solo deudor, acreedor o un administrador pueden marcarla' end);
  end if;

  -- R.16.A: pago externo — solo money + open (el RPC exige status='open') y
  -- solo el acreedor puede atestiguar que recibió el pago.
  if v_ob.obligation_kind = 'money' and v_ob.status = 'open' then
    v_actions := v_actions || public._aa('mark_paid_external', 'Me pagaron por fuera', 'obligations',
      v_is_creditor,
      case when v_is_creditor then 'Confirmas que recibiste el pago fuera de la app'
           else 'Solo quien recibe el pago puede marcarlo' end);
  end if;

  -- FE.2: 'dispute' y 'cancel' removidas hasta que existan sus RPCs.

  if v_active then
    v_actions := v_actions || public._aa('forgive', 'Condonar', 'obligations',
      v_is_creditor, case when v_is_creditor then 'Eres el acreedor y puedes condonar'
                          else 'Solo el acreedor puede condonar' end);
  end if;

  if v_active then
    v_actions := v_actions || public._aa('edit_obligation', 'Editar obligación', 'obligations',
      v_is_creditor or v_is_manager,
      case when v_is_creditor then 'Eres el acreedor y puedes editar'
           when v_is_manager then 'Tienes permiso para administrar dinero'
           else 'Solo el acreedor o un administrador pueden editar la obligación' end);
  end if;

  if v_ob.context_actor_id is not null then
    return public._aa_apply_governance_mode(v_actions, v_ob.context_actor_id);
  end if;
  return v_actions;
end; $$;

comment on function public.obligation_available_actions(uuid, uuid) is
  'R.16.A — acciones canónicas de una obligación: mark_completed (non-money) ·
mark_paid_external (money+open, creditor) · forgive · edit_obligation. Base FE.2:
ninguna acción visible sin RPC de dispatch.';
