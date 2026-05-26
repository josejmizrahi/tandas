-- 20260526020000 — member_obligations_view v2 (Money 2.0 Phase 4.2 wire).
--
-- Bug fix (founder reported 2026-05-26): "al liquidar deuda peer-to-peer,
-- la deuda se duplica en vez de cerrarse".
--
-- Diagnóstico
-- ===========
-- La v1 (mig 20260525230000) computaba `receivable_cents` como
-- `SUM(expense.amount_cents WHERE to_member=me) - reimbursed`. Eso
-- DOBLE-CUENTA la parte del propio fronter (Alice fronts $100 con
-- split [Alice:$50, Bob:$50] → receivable_cents=$100 en vez de $50).
-- Encima, `net_peer_position_cents` sumaba `settlement_received_cents`
-- como crédito adicional, sin restar lo recibido del receivable —
-- entonces cuando Bob pagaba sus $50 a Alice, Alice subía de $100 a
-- $150 (en lugar de bajar a $50).
--
-- Phase 4.1 (mig 20260526000000) y Phase 4.2 (migs 20260526010000 +
-- 20260526010500) ya materializan las obligations peer-to-peer y los
-- settlements con allocation FIFO via el bridge. Lo que faltaba era
-- que la vista LEYERA esos datos en vez de re-derivar del ledger crudo.
--
-- Nuevo modelo
-- ============
--   peer_receivable  = Σ (obligation.outstanding) WHERE owed_to=me
--   peer_obligation  = Σ (obligation.outstanding) WHERE owed_by=me
--   pool_receivable  = expenses fronteados SIN split_breakdown
--                      (toda la cantidad le toca al fronter pq el
--                      pool aún no le ha repagado), menos reimbursed
--                      + payouts del pool
--   fine_obligation  = fines outstanding (issued − paid − voided)
--
-- Donde:
--   `obligation.outstanding` = obligation.amount_cents − Σ bridge.amount_applied_cents
--   `obligations.status IN ('open','partially_paid','paid_pending_confirmation')`
--   `disputed` y `voided` excluidos (no actionables hasta resolverse).
--
-- Columnas exportadas (orden preservado por CREATE OR REPLACE):
--   stake_cents               — sin cambio
--   stake_in_kind_cents       — sin cambio
--   receivable_cents          ← peer_receivable + pool_receivable_neto
--   obligation_cents          ← fine_obligation (mantiene semántica
--                               legacy: "multas pendientes" en UI)
--   settlement_received_cents ← histórico (informativo)
--   settlement_sent_cents     ← histórico (informativo)
--   net_peer_position_cents   ← receivable − peer_obligation − fine_obligation
--                               (settlements ya están baked in via bridge
--                               allocation, no se vuelven a sumar/restar)
--
-- Consecuencia: cuando se cierra una obligation (status='settled') o
-- se aplica un settlement parcial (status='partially_paid' con bridge
-- amount_applied), `peer_receivable` y `peer_obligation` bajan
-- automáticamente — y el net baja con ellos. La deuda deja de duplicarse.
--
-- Compatibilidad
-- ==============
-- Columnas idénticas (nombre + tipo + orden). iOS struct
-- `MemberObligationSummary` no cambia. Consumidores no requieren cambio.
--
-- Rollback
-- ========
-- create or replace view public.member_obligations_view as <v1>
-- (mig 20260525230000 sigue siendo el contenido referencia).

create or replace view public.member_obligations_view as
with stake_cash as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'contribution'
     and coalesce((metadata->>'in_kind'), 'false') <> 'true'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
stake_in_kind as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'contribution'
     and (metadata->>'in_kind') = 'true'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
-- Peer receivable: outstanding obligations TO this member, net of bridge
-- allocations (Phase 4.2). This is the canonical "los demás te deben".
peer_receivable as (
  select o.group_id,
         o.owed_to_member_id as member_id,
         o.currency,
         sum(o.amount_cents - coalesce(applied.applied_cents, 0))::bigint as cents
    from public.obligations o
    left join lateral (
      select coalesce(sum(so.amount_applied_cents), 0)::bigint as applied_cents
        from public.settlement_obligations so
       where so.obligation_id = o.id
    ) applied on true
   where o.status in ('open', 'partially_paid', 'paid_pending_confirmation')
   group by o.group_id, o.owed_to_member_id, o.currency
),
-- Peer obligation: outstanding obligations BY this member, net of
-- bridge allocations. Canonical "le debes a alguien".
peer_obligation as (
  select o.group_id,
         o.owed_by_member_id as member_id,
         o.currency,
         sum(o.amount_cents - coalesce(applied.applied_cents, 0))::bigint as cents
    from public.obligations o
    left join lateral (
      select coalesce(sum(so.amount_applied_cents), 0)::bigint as applied_cents
        from public.settlement_obligations so
       where so.obligation_id = o.id
    ) applied on true
   where o.status in ('open', 'partially_paid', 'paid_pending_confirmation')
   group by o.group_id, o.owed_by_member_id, o.currency
),
-- Pool receivable: expense rows WITHOUT split_breakdown — toda la
-- cantidad es deuda del pool al fronter. Excluye expenses con split
-- (esos ya están en `obligations` y se cuentan vía peer_receivable).
pool_receivable as (
  select group_id,
         to_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'expense'
     and to_member_id is not null
     and (
       not (metadata ? 'split_breakdown')
       or jsonb_typeof(metadata->'split_breakdown') <> 'array'
       or jsonb_array_length(metadata->'split_breakdown') = 0
     )
   group by group_id, to_member_id, currency
),
-- Pool payments back to a member (reimbursement / payout). Cancelan
-- pool_receivable. NO afectan peer (esas se cancelan via settlements
-- → bridge → obligation.status).
reimbursed as (
  select group_id,
         coalesce(from_member_id, to_member_id) as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where (type = 'reimbursement'
            and (from_member_id is not null or to_member_id is not null))
      or (type = 'payout' and to_member_id is not null)
   group by group_id, coalesce(from_member_id, to_member_id), currency
),
fines_issued as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'fine_issued'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
fines_paid as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'fine_paid'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
fines_voided as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'fine_voided'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
-- Settlements: kept as informational lifetime totals. NOT added/
-- subtracted from net_peer_position — bridge allocation already
-- did that via peer_receivable / peer_obligation.
settlements_received as (
  select group_id,
         to_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'settlement'
     and to_member_id is not null
   group by group_id, to_member_id, currency
),
settlements_sent as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'settlement'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
all_keys as (
  select group_id, member_id, currency from stake_cash
  union
  select group_id, member_id, currency from stake_in_kind
  union
  select group_id, member_id, currency from peer_receivable
  union
  select group_id, member_id, currency from peer_obligation
  union
  select group_id, member_id, currency from pool_receivable
  union
  select group_id, member_id, currency from reimbursed
  union
  select group_id, member_id, currency from fines_issued
  union
  select group_id, member_id, currency from fines_paid
  union
  select group_id, member_id, currency from fines_voided
  union
  select group_id, member_id, currency from settlements_received
  union
  select group_id, member_id, currency from settlements_sent
)
select
  k.group_id,
  k.member_id,
  k.currency,
  coalesce(sc.cents, 0)::bigint  as stake_cents,
  coalesce(sk.cents, 0)::bigint  as stake_in_kind_cents,
  (
    coalesce(pr.cents, 0)
    + greatest(coalesce(plr.cents, 0) - coalesce(re.cents, 0), 0)
  )::bigint as receivable_cents,
  greatest(
    coalesce(fi.cents, 0) - coalesce(fp.cents, 0) - coalesce(fv.cents, 0),
    0
  )::bigint as obligation_cents,
  coalesce(sr.cents, 0)::bigint  as settlement_received_cents,
  coalesce(ss.cents, 0)::bigint  as settlement_sent_cents,
  (
    coalesce(pr.cents, 0)
    + greatest(coalesce(plr.cents, 0) - coalesce(re.cents, 0), 0)
    - coalesce(pob.cents, 0)
    - greatest(coalesce(fi.cents, 0) - coalesce(fp.cents, 0) - coalesce(fv.cents, 0), 0)
  )::bigint as net_peer_position_cents
from all_keys k
left join stake_cash           sc  on (sc.group_id,  sc.member_id,  sc.currency)  = (k.group_id, k.member_id, k.currency)
left join stake_in_kind        sk  on (sk.group_id,  sk.member_id,  sk.currency)  = (k.group_id, k.member_id, k.currency)
left join peer_receivable      pr  on (pr.group_id,  pr.member_id,  pr.currency)  = (k.group_id, k.member_id, k.currency)
left join peer_obligation      pob on (pob.group_id, pob.member_id, pob.currency) = (k.group_id, k.member_id, k.currency)
left join pool_receivable      plr on (plr.group_id, plr.member_id, plr.currency) = (k.group_id, k.member_id, k.currency)
left join reimbursed           re  on (re.group_id,  re.member_id,  re.currency)  = (k.group_id, k.member_id, k.currency)
left join fines_issued         fi  on (fi.group_id,  fi.member_id,  fi.currency)  = (k.group_id, k.member_id, k.currency)
left join fines_paid           fp  on (fp.group_id,  fp.member_id,  fp.currency)  = (k.group_id, k.member_id, k.currency)
left join fines_voided         fv  on (fv.group_id,  fv.member_id,  fv.currency)  = (k.group_id, k.member_id, k.currency)
left join settlements_received sr  on (sr.group_id,  sr.member_id,  sr.currency)  = (k.group_id, k.member_id, k.currency)
left join settlements_sent     ss  on (ss.group_id,  ss.member_id,  ss.currency)  = (k.group_id, k.member_id, k.currency);

comment on view public.member_obligations_view is
  'Money 2.0 Phase 4.2 wire (mig 20260526020000): per (group, member, currency) money breakdown. NOW derives peer receivable/obligation from `obligations` + `settlement_obligations` tables (Phase 4.1/4.2). `receivable_cents` = peer outstanding TO me + pool expenses I fronted without split. `obligation_cents` = fines pendientes. `net_peer_position_cents` = receivable − peer obligations FROM me − fines. Settlements ya están baked in via bridge allocation; las columnas settlement_*_cents son sólo informativas. Fixes the founder-reported "deuda duplicada al pagar" bug from v1 (mig 20260525230000).';

grant select on public.member_obligations_view to authenticated;
