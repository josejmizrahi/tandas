-- ============================================================================
-- AUDIT.19 — RLS fast-path II: tablas calientes con quals compuestos (2026-06-11)
-- ============================================================================
-- Extiende audit_18 a las 9 tablas de mayor lectura con quals compuestos.
-- Dos transformaciones, ambas con equivalencia 1:1 verificada contra el qual
-- vigente en pg_policies:
--   a) `is_context_member(X)` → `X IN (SELECT my_context_ids())`  (hashed set,
--      una evaluación por query). `X IS NOT NULL AND ...` se vuelve implícito
--      (NULL nunca ∈ set).
--   b) `col = current_actor_id()` → `col = (SELECT current_actor_id())`
--      (initplan: una llamada por query en vez de por fila — patrón
--      auth_rls_initplan de Supabase).
--   c) EXISTS correlacionados por tabla puente → `fk IN (SELECT id FROM puente
--      WHERE contexto ∈ fastpath)` (semi-join hasheable).
--
-- FUERA de esta tanda (documentado en el plan): `resources` y `actors` — sus
-- quals dependen de funciones de derechos por fila (_actor_can_view_resource /
-- visibilidad de actores) cuya reescritura es trabajo dedicado.
-- Verificación: EXPLAIN (hashed SubPlan / InitPlan) + suite _smoke_mvp2_*
-- completa en live (visibilidad dentro/fuera de contexto).
-- ============================================================================

-- activity_events — la tabla más leída del producto (qual original: 684 chars
-- por fila: 4 ramas con is_context_member + 2 EXISTS con current_actor_id())
drop policy if exists activity_select on public.activity_events;
create policy activity_select on public.activity_events
  for select to authenticated
  using (
    actor_id = (select public.current_actor_id())
    or context_actor_id in (select public.my_context_ids())
    or (obligation_id is not null and exists (
          select 1 from public.obligations o
          where o.id = activity_events.obligation_id
            and (select public.current_actor_id()) in (o.debtor_actor_id, o.creditor_actor_id)))
    or (resource_id is not null and exists (
          select 1 from public.resource_rights rr
          where rr.resource_id = activity_events.resource_id
            and rr.holder_actor_id = (select public.current_actor_id())
            and rr.right_kind = any (array['VIEW','USE','MANAGE','OWN','BENEFICIARY'])
            and rr.revoked_at is null
            and rr.expired_at is null))
  );

-- obligations
drop policy if exists obligations_select on public.obligations;
create policy obligations_select on public.obligations
  for select to authenticated
  using (
    debtor_actor_id = (select public.current_actor_id())
    or creditor_actor_id = (select public.current_actor_id())
    or context_actor_id in (select public.my_context_ids())
  );

-- money_transactions
drop policy if exists txn_select on public.money_transactions;
create policy txn_select on public.money_transactions
  for select to authenticated
  using (
    from_actor_id = (select public.current_actor_id())
    or to_actor_id = (select public.current_actor_id())
    or created_by_actor_id = (select public.current_actor_id())
    or context_actor_id in (select public.my_context_ids())
  );

-- money_splits (puente vía money_transactions)
drop policy if exists splits_select on public.money_splits;
create policy splits_select on public.money_splits
  for select to authenticated
  using (
    actor_id = (select public.current_actor_id())
    or transaction_id in (
        select t.id from public.money_transactions t
        where t.context_actor_id in (select public.my_context_ids()))
  );

-- event_participants (puente vía calendar_events)
drop policy if exists participants_select on public.event_participants;
create policy participants_select on public.event_participants
  for select to authenticated
  using (
    participant_actor_id = (select public.current_actor_id())
    or event_id in (
        select e.id from public.calendar_events e
        where e.context_actor_id in (select public.my_context_ids()))
  );

-- decision_votes (puente vía decisions)
drop policy if exists votes_select on public.decision_votes;
create policy votes_select on public.decision_votes
  for select to authenticated
  using (
    voter_actor_id = (select public.current_actor_id())
    or decision_id in (
        select d.id from public.decisions d
        where d.context_actor_id in (select public.my_context_ids()))
  );

-- documents
drop policy if exists documents_select on public.documents;
create policy documents_select on public.documents
  for select to authenticated
  using (
    owner_actor_id = (select public.current_actor_id())
    or created_by_actor_id = (select public.current_actor_id())
    or context_actor_id in (select public.my_context_ids())
  );

-- settlement_batches
drop policy if exists batches_select on public.settlement_batches;
create policy batches_select on public.settlement_batches
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

-- settlement_items (puente vía settlement_batches)
drop policy if exists items_select on public.settlement_items;
create policy items_select on public.settlement_items
  for select to authenticated
  using (
    from_actor_id = (select public.current_actor_id())
    or to_actor_id = (select public.current_actor_id())
    or settlement_batch_id in (
        select b.id from public.settlement_batches b
        where b.context_actor_id in (select public.my_context_ids()))
  );
