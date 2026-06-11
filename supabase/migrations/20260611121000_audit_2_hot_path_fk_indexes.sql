-- ============================================================================
-- AUDIT.2 — Índices en FKs de hot paths (2026-06-11)
-- ============================================================================
-- Origen: Plans/Active/SupabaseArchitectureAudit.md §9 (advisor: 77 FKs sin
-- índice). Se indexan SOLO los hot paths (activity, money, settlement,
-- obligations, votos, documentos, suscripciones, reservas); las FKs de
-- catálogos fríos se omiten a propósito. Todo additive, IF NOT EXISTS,
-- parciales donde la columna es mayormente NULL.
-- Rollback: DROP INDEX IF EXISTS de cada nombre listado.
-- ============================================================================

-- Activity: lookups por entidad vinculada (feeds de detalle, dispatcher R6)
create index if not exists idx_activity_resource
  on public.activity_events (resource_id, occurred_at desc) where resource_id is not null;
create index if not exists idx_activity_decision
  on public.activity_events (decision_id, occurred_at desc) where decision_id is not null;
create index if not exists idx_activity_obligation
  on public.activity_events (obligation_id, occurred_at desc) where obligation_id is not null;
create index if not exists idx_activity_subject
  on public.activity_events (subject_type, subject_id) where subject_id is not null;

-- Money: cara/contracara y vínculos a evento/obligación
create index if not exists idx_txn_from_actor
  on public.money_transactions (from_actor_id) where from_actor_id is not null;
create index if not exists idx_txn_to_actor
  on public.money_transactions (to_actor_id) where to_actor_id is not null;
create index if not exists idx_txn_event
  on public.money_transactions (event_id) where event_id is not null;
create index if not exists idx_txn_obligation
  on public.money_transactions (obligation_id) where obligation_id is not null;
create index if not exists idx_splits_actor
  on public.money_splits (actor_id);

-- Obligations: provenance (4 sources) + detector de vencidas (pg_cron R6.C)
create index if not exists idx_obligations_source_event
  on public.obligations (source_event_id) where source_event_id is not null;
create index if not exists idx_obligations_source_rule
  on public.obligations (source_rule_id) where source_rule_id is not null;
create index if not exists idx_obligations_source_decision
  on public.obligations (source_decision_id) where source_decision_id is not null;
create index if not exists idx_obligations_source_reservation
  on public.obligations (source_reservation_id) where source_reservation_id is not null;
create index if not exists idx_obligations_due
  on public.obligations (status, due_at) where due_at is not null;

-- Settlement: items por actor (handshake 2 vías) y batches por contexto
create index if not exists idx_settlement_items_from
  on public.settlement_items (from_actor_id, status);
create index if not exists idx_settlement_items_to
  on public.settlement_items (to_actor_id, status);
create index if not exists idx_settlement_batches_context
  on public.settlement_batches (context_actor_id, status);

-- Decisions / Events
create index if not exists idx_decision_votes_voter
  on public.decision_votes (voter_actor_id);
create index if not exists idx_events_host
  on public.calendar_events (host_actor_id) where host_actor_id is not null;

-- Documents: adjuntos por entidad
create index if not exists idx_documents_resource
  on public.documents (resource_id) where resource_id is not null;
create index if not exists idx_documents_event
  on public.documents (event_id) where event_id is not null;
create index if not exists idx_documents_decision
  on public.documents (decision_id) where decision_id is not null;

-- Subscriptions: fan-out "¿quién sigue a X?" (los uniques existentes llevan
-- subscriber primero y no sirven para esta dirección)
create index if not exists idx_subscriptions_target_actor
  on public.subscriptions (target_actor_id) where target_actor_id is not null and removed_at is null;
create index if not exists idx_subscriptions_target_resource
  on public.subscriptions (target_resource_id) where target_resource_id is not null and removed_at is null;
create index if not exists idx_subscriptions_target_decision
  on public.subscriptions (target_decision_id) where target_decision_id is not null and removed_at is null;
create index if not exists idx_subscriptions_target_event
  on public.subscriptions (target_event_id) where target_event_id is not null and removed_at is null;
create index if not exists idx_subscriptions_target_obligation
  on public.subscriptions (target_obligation_id) where target_obligation_id is not null and removed_at is null;

-- Reservations: conflictos por recurso/reserva B y reservas por contexto/beneficiario
create index if not exists idx_resconflicts_resource
  on public.reservation_conflicts (resource_id);
create index if not exists idx_resconflicts_reservation_b
  on public.reservation_conflicts (reservation_b_id);
create index if not exists idx_reservations_context
  on public.resource_reservations (context_actor_id, starts_at desc);
create index if not exists idx_reservations_reserved_for
  on public.resource_reservations (reserved_for_actor_id) where reserved_for_actor_id is not null;
