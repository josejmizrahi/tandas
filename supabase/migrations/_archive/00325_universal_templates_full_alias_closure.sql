-- 00325 — Seed 10 universal templates to close all remaining alias mismatches.
--
-- Source: Plans/Active/UniversalRuleTemplates.md §14.7.
-- Continuation of migs 00320 + 00321 (alias-correctness audit cleanup).
--
-- Audit at 2026-05-18 post-00321: 9 legacy aliases still pointed at universals
-- with different trigger semantics. This mig ships sibling universals with the
-- right composition for each, then re-aliases the legacy rows so engine
-- evaluation matches gallery expectations end-to-end.
--
-- 10 new universals (all Category C — Obligation or D — Governance):
--   1. cancellation_consequence           (eventCancelled + alwaysTrue + fine)
--   2. late_return_consequence            (checkoutOverdue + alwaysTrue + fine)
--   3. deadline_consequence               (hoursBeforeEvent + alwaysTrue + fine)
--   4. expiration_warning                 (rightExpiringSoon + daysBeforeExpiry + emitWarning)
--   5. booking_cancellation_consequence   (bookingCancelled + cancelledWithinHours + fine)
--   6. damage_approval                    (damageReported + damageAmountAbove + requireApproval)
--   7. damage_vote_required               (damageReported + damageSeverityAbove + startVote)
--   8. vote_required                      (ledgerEntryCreated + amountAbove + startVote)
--   9. transfer_vote_required             (assetTransferred + transferAmountAbove + startVote)
--  10. booking_vote_required              (bookingCreated + bookingDurationAbove + startVote)
--
-- Re-aliases (9 legacy templates -> their trigger-correct universal):
--   cancellation_fee                     -> cancellation_consequence
--   not_returned_fine                    -> late_return_consequence
--   host_no_menu_fine                    -> deadline_consequence
--   right_expiration_warning             -> expiration_warning
--   space_cancellation_late_fine         -> booking_cancellation_consequence
--   damage_approval_required             -> damage_approval
--   space_damage_temporary_closure_vote  -> damage_vote_required
--   expense_threshold_vote               -> vote_required
--   transfer_large_vote                  -> transfer_vote_required
--   space_long_booking_vote              -> booking_vote_required
--
-- Composes only existing shape pieces (00084 + 00193 + 00194 + 00226 + 00268).
-- Zero new evaluator code in ruleEngine.ts. Zero new atom types.
--
-- Net result post-mig:
--   Gallery visible (beta1 + alias_of IS NULL): 6 -> 16
--   Alias trigger mismatches: 9 -> 0
--   Total templates: 24 -> 34

-- =============================================================================
-- Helper: shared upsert pattern (we repeat the long ON CONFLICT block per row
-- so the mig stays declarative and easy to rollback).
-- =============================================================================

-- =============================================================================
-- 1. cancellation_consequence — multa cuando se cancela el evento completo
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'cancellation_consequence',
  'Cobrar si se cancela el evento',
  'Cuando el organizador cancela el evento completo (no solo una persona, sino el evento entero), se cobra una multa a los miembros que confirmaron. Cubre costos hundidos: comida comprada, salón reservado, recurso ya apartado.',
  'attendance', 'penalty', array['ledger']::text[],
  jsonb_build_object('amount', 200),
  jsonb_build_object('trigger_shape_id','eventCancelled','condition_shape_ids',jsonb_build_array('alwaysTrue'),'consequence_shape_ids',jsonb_build_array('fine'),'scope_hint','series'),
  'active', 24,
  'C — Obligation',
  array[
    'No castiga al miembro que canceló individualmente (eso es Cobrar por cancelar tarde)',
    'No castiga al que no llegó (eso es Cobrar a quien no llegó)',
    'No avisa nada — sólo se aplica cuando el evento ya está cancelado'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Cenas','label_grupo','Multa si se cancela la cena','params',jsonb_build_object('amount',200)),
    jsonb_build_object('vertical','Fútbol','label_grupo','Multa si se cancela el partido','params',jsonb_build_object('amount',100)),
    jsonb_build_object('vertical','Palco','label_grupo','Multa si se cancela la función','params',jsonb_build_object('amount',500)),
    jsonb_build_object('vertical','Coworking','label_grupo','Cargo si se cancela el taller','params',jsonb_build_object('amount',300)),
    jsonb_build_object('vertical','Familia','label_grupo','Multa simbólica si se cancela la comida','params',jsonb_build_object('amount',50)),
    jsonb_build_object('vertical','Asociación','label_grupo','Multa si se cancela la asamblea','params',jsonb_build_object('amount',400))
  ),
  'Si {{resource.name}} se cancela, se cobra ${{amount}} a cada confirmado.',
  array['same_scope_overlapping','consequence_missing_capability']::text[],
  'beta1', array['resource','series']::text[],
  array['happy_path_fine_issued_on_cancel','no_confirmed_no_fine','rule_inactive_no_fine','replay_idempotent','capability_ledger_missing_blocks_publish']::text[]
);

-- =============================================================================
-- 2. late_return_consequence — multa cuando no se devuelve un activo a tiempo
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'late_return_consequence',
  'Cobrar por no devolver a tiempo',
  'Cuando un miembro tiene un activo en custodia y no lo regresa en el plazo acordado, se le cobra una multa. Aplica a cualquier objeto que se presta o se entrega bajo custodia con compromiso de devolución.',
  'custody', 'penalty', array['ledger']::text[],
  jsonb_build_object('amount', 200, 'grace_days', 1),
  jsonb_build_object('trigger_shape_id','checkoutOverdue','condition_shape_ids',jsonb_build_array('alwaysTrue'),'consequence_shape_ids',jsonb_build_array('fine'),'scope_hint','resource_type'),
  'active', 25,
  'F — Custody',
  array[
    'No castiga por daño al activo (eso es Aprobación por daño)',
    'No avisa antes del deadline (eso es Exigir algo antes de una fecha)',
    'No bloquea futuras solicitudes (eso es Restringir acceso)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Familia','label_grupo','Multa si no devuelves el coche a tiempo','params',jsonb_build_object('amount',300,'grace_days',1)),
    jsonb_build_object('vertical','Club','label_grupo','Multa por no devolver equipo','params',jsonb_build_object('amount',200,'grace_days',2)),
    jsonb_build_object('vertical','Coworking','label_grupo','Cargo por retener la sala/recurso','params',jsonb_build_object('amount',500,'grace_days',0)),
    jsonb_build_object('vertical','Biblioteca grupal','label_grupo','Multa por libro vencido','params',jsonb_build_object('amount',50,'grace_days',7)),
    jsonb_build_object('vertical','Asociación','label_grupo','Multa por retener material','params',jsonb_build_object('amount',150,'grace_days',3)),
    jsonb_build_object('vertical','Roommates','label_grupo','Multa por no devolver herramienta común','params',jsonb_build_object('amount',100,'grace_days',2))
  ),
  'Si pasan más de {{grace_days}} día(s) después del deadline sin devolver {{resource.name}}, se cobra ${{amount}}.',
  array['same_scope_overlapping','consequence_missing_capability']::text[],
  'beta1', array['resource','resource_type']::text[],
  array['happy_path_fine_after_grace','returned_within_grace_no_fine','rule_inactive_no_fine','replay_idempotent','capability_ledger_missing_blocks_publish']::text[]
);

-- =============================================================================
-- 3. deadline_consequence — multa cuando NO se hace algo antes del deadline
-- (variante con consecuencia monetaria del deadline_enforcement, que sólo avisa)
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'deadline_consequence',
  'Cobrar si no se hace algo antes de una fecha',
  'Cuando una obligación con deadline no se cumple a tiempo, se cobra una multa. Variante monetaria de Exigir algo antes de una fecha — útil cuando un aviso no basta (subir documento, proponer menú, asignar host, pagar a tiempo).',
  'attendance', 'penalty', array['ledger']::text[],
  jsonb_build_object('hours', 24, 'amount', 100),
  jsonb_build_object('trigger_shape_id','hoursBeforeEvent','condition_shape_ids',jsonb_build_array('alwaysTrue'),'consequence_shape_ids',jsonb_build_array('fine'),'scope_hint','series'),
  'active', 26,
  'C — Obligation',
  array[
    'No solo avisa (eso es Exigir algo antes de una fecha)',
    'No castiga al que llegó tarde físicamente (eso es Aplicar consecuencia si alguien no cumple)',
    'No pide aprobación (eso es Pedir aprobación antes de una acción)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Cenas','label_grupo','Multa al host si no propone menú','params',jsonb_build_object('hours',24,'amount',100)),
    jsonb_build_object('vertical','Fútbol','label_grupo','Multa al capitán si no arma lineup','params',jsonb_build_object('hours',12,'amount',150)),
    jsonb_build_object('vertical','Palco','label_grupo','Multa si no se eligen boletos','params',jsonb_build_object('hours',48,'amount',300)),
    jsonb_build_object('vertical','Asociación','label_grupo','Multa por no subir documento a tiempo','params',jsonb_build_object('hours',72,'amount',500)),
    jsonb_build_object('vertical','Roommates','label_grupo','Multa por pagar renta tarde','params',jsonb_build_object('hours',120,'amount',200)),
    jsonb_build_object('vertical','Viajes','label_grupo','Cargo por no confirmar reserva grupal','params',jsonb_build_object('hours',96,'amount',400))
  ),
  'Si {{hours}} horas antes de {{resource.name}} la acción requerida no se completó, se cobra ${{amount}}.',
  array['same_scope_overlapping','impossible_condition']::text[],
  'beta1', array['resource','series']::text[],
  array['happy_path_fine_at_deadline','done_before_deadline_no_fine','rule_inactive_no_fine','replay_idempotent','capability_ledger_missing_blocks_publish']::text[]
);

-- =============================================================================
-- 4. expiration_warning — aviso antes de que un derecho/recurso expire
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'expiration_warning',
  'Avisar antes de que algo expire',
  'Cuando faltan N días o menos para que un derecho, acceso, membresía o contrato vencen, el grupo recibe un aviso. Permite renovar, ejercer, transferir o decidir qué hacer antes de perderlo.',
  'governance', 'behavior', array[]::text[],
  jsonb_build_object('days_before', 7),
  jsonb_build_object('trigger_shape_id','rightExpiringSoon','condition_shape_ids',jsonb_build_array('daysBeforeExpiry'),'consequence_shape_ids',jsonb_build_array('emitWarning'),'scope_hint','resource_type'),
  'active', 27,
  'D — Governance',
  array[
    'No renueva automáticamente — solo avisa',
    'No transfiere ni revoca — el grupo decide qué hacer',
    'No cobra nada (eso es Cobrar si no se hace algo)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Club','label_grupo','Aviso antes de que vence la membresía','params',jsonb_build_object('days_before',14)),
    jsonb_build_object('vertical','Palco','label_grupo','Aviso antes de que venza el palco anual','params',jsonb_build_object('days_before',30)),
    jsonb_build_object('vertical','Familia','label_grupo','Aviso antes de que venza la cobertura del seguro','params',jsonb_build_object('days_before',21)),
    jsonb_build_object('vertical','Asociación','label_grupo','Aviso antes de que venza el dominio o servicio','params',jsonb_build_object('days_before',14)),
    jsonb_build_object('vertical','Coworking','label_grupo','Aviso antes de que venza el contrato','params',jsonb_build_object('days_before',30)),
    jsonb_build_object('vertical','Viajes','label_grupo','Aviso antes de que venza la reserva colectiva','params',jsonb_build_object('days_before',7))
  ),
  'Cuando falten {{days_before}} días o menos para que {{resource.name}} expire, el grupo recibe un aviso.',
  array['same_scope_overlapping']::text[],
  'beta1', array['resource','resource_type']::text[],
  array['happy_path_warning_emitted_at_threshold','far_from_expiry_no_warning','rule_inactive_no_warning','replay_idempotent','multiple_resources_distinct_warnings']::text[]
);

-- =============================================================================
-- 5. booking_cancellation_consequence — multa por cancelar reserva tarde
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'booking_cancellation_consequence',
  'Cobrar por cancelar reserva tarde',
  'Cuando alguien cancela una reserva con menos de N horas de anticipación, se le cobra una multa. Distinto de Cobrar por cancelar tarde — ese aplica a RSVPs (asistencia); este a reservas (slot/space ocupado que no se libera a tiempo).',
  'attendance', 'penalty', array['ledger']::text[],
  jsonb_build_object('hours', 24, 'amount', 200),
  jsonb_build_object('trigger_shape_id','bookingCancelled','condition_shape_ids',jsonb_build_array('cancelledWithinHours'),'consequence_shape_ids',jsonb_build_array('fine'),'scope_hint','resource_type'),
  'active', 28,
  'C — Obligation',
  array[
    'No castiga a quien cancela su asistencia (RSVP) — eso es Cobrar por cancelar tarde',
    'No castiga al que reserva por mucho tiempo (eso es Voto para reservas largas)',
    'No castiga al que daña (eso es Aprobación por daño)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Coworking','label_grupo','Multa por cancelar la sala tarde','params',jsonb_build_object('hours',2,'amount',200)),
    jsonb_build_object('vertical','Palco','label_grupo','Multa por cancelar el palco tarde','params',jsonb_build_object('hours',24,'amount',500)),
    jsonb_build_object('vertical','Club','label_grupo','Multa por cancelar reserva tarde','params',jsonb_build_object('hours',12,'amount',150)),
    jsonb_build_object('vertical','Viajes','label_grupo','Cargo por cancelar slot del viaje','params',jsonb_build_object('hours',72,'amount',1000)),
    jsonb_build_object('vertical','Asociación','label_grupo','Multa por cancelar uso de espacio','params',jsonb_build_object('hours',48,'amount',300)),
    jsonb_build_object('vertical','Familia','label_grupo','Multa simbólica por cancelar uso del coche','params',jsonb_build_object('hours',6,'amount',50))
  ),
  'Si alguien cancela su reserva de {{resource.name}} con menos de {{hours}} horas de anticipación, se cobra ${{amount}}.',
  array['same_scope_overlapping','consequence_missing_capability']::text[],
  'beta1', array['resource','resource_type']::text[],
  array['happy_path_fine_when_cancel_within_window','cancelled_before_window_no_fine','rule_inactive_no_fine','duplicate_cancel_single_fine','capability_ledger_missing_blocks_publish']::text[]
);

-- =============================================================================
-- 6. damage_approval — daño grande requiere aprobación
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'damage_approval',
  'Pedir aprobación si hay daño grande',
  'Cuando alguien reporta un daño con costo estimado mayor a un umbral, se requiere aprobación antes de cualquier acción correctiva (reparar, cobrar, suspender uso). Permite separar reportes menores (auto-resueltos) de daños serios que necesitan decisión grupal.',
  'governance', 'approval', array[]::text[],
  jsonb_build_object('threshold_cents', 500000),
  jsonb_build_object('trigger_shape_id','damageReported','condition_shape_ids',jsonb_build_array('damageAmountAbove'),'consequence_shape_ids',jsonb_build_array('requireApproval'),'scope_hint','resource_type'),
  'active', 29,
  'D — Governance',
  array[
    'No cierra el recurso (eso es Voto para cerrar por daño)',
    'No cobra al causante (eso es Cobrar por no devolver)',
    'No genera aviso solo (eso requiere otra rule)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Familia','label_grupo','Aprobar reparaciones grandes del coche','params',jsonb_build_object('threshold_cents',300000)),
    jsonb_build_object('vertical','Club','label_grupo','Aprobar daño grande al equipo','params',jsonb_build_object('threshold_cents',500000)),
    jsonb_build_object('vertical','Palco','label_grupo','Aprobar daño grande al palco','params',jsonb_build_object('threshold_cents',1000000)),
    jsonb_build_object('vertical','Coworking','label_grupo','Aprobar daño al mobiliario','params',jsonb_build_object('threshold_cents',200000)),
    jsonb_build_object('vertical','Asociación','label_grupo','Aprobar reparación del local','params',jsonb_build_object('threshold_cents',2000000)),
    jsonb_build_object('vertical','Roommates','label_grupo','Aprobar reparación del depa','params',jsonb_build_object('threshold_cents',100000))
  ),
  'Cuando se reporte un daño en {{resource.name}} con costo mayor a ${{threshold}}, requiere aprobación antes de actuar.',
  array['same_scope_overlapping','approval_loop']::text[],
  'beta1', array['resource','resource_type']::text[],
  array['happy_path_approval_required_above_threshold','below_threshold_no_approval','rule_inactive_no_approval','approval_loop_blocks_publish','replay_idempotent']::text[]
);

-- =============================================================================
-- 7. damage_vote_required — daño grave abre voto
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'damage_vote_required',
  'Voto cuando hay daño grave',
  'Cuando se reporta un daño con severidad por encima de un nivel acordado, se abre una votación grupal para decidir qué hacer (reparar, suspender, cerrar, cobrar). Útil cuando la decisión amerita consenso, no aprobación unilateral.',
  'governance', 'approval', array[]::text[],
  jsonb_build_object('level', 'major', 'duration_hours', 48, 'quorum_percent', 50, 'threshold_percent', 66),
  jsonb_build_object('trigger_shape_id','damageReported','condition_shape_ids',jsonb_build_array('damageSeverityAbove'),'consequence_shape_ids',jsonb_build_array('startVote'),'scope_hint','resource_type'),
  'active', 30,
  'D — Governance',
  array[
    'No es aprobación unilateral (eso es Pedir aprobación si hay daño grande)',
    'No cobra directamente (eso es Cobrar por no devolver)',
    'No cierra automáticamente — el voto decide'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Club','label_grupo','Voto si hay daño grave al equipo','params',jsonb_build_object('level','major')),
    jsonb_build_object('vertical','Palco','label_grupo','Voto si hay daño grave al palco','params',jsonb_build_object('level','major')),
    jsonb_build_object('vertical','Coworking','label_grupo','Voto si hay daño grave al espacio','params',jsonb_build_object('level','major')),
    jsonb_build_object('vertical','Asociación','label_grupo','Voto si hay daño grave al local','params',jsonb_build_object('level','critical')),
    jsonb_build_object('vertical','Familia','label_grupo','Voto si el coche sufrió daño grave','params',jsonb_build_object('level','major')),
    jsonb_build_object('vertical','Viajes','label_grupo','Voto si daño grave al recurso colectivo','params',jsonb_build_object('level','major'))
  ),
  'Cuando se reporte un daño "{{level}}" o peor en {{resource.name}}, se abre una votación de {{duration_hours}}h.',
  array['same_scope_overlapping']::text[],
  'beta1', array['resource','resource_type']::text[],
  array['happy_path_vote_started_on_severity','below_severity_no_vote','rule_inactive_no_vote','replay_idempotent','vote_outcome_recorded']::text[]
);

-- =============================================================================
-- 8. vote_required — voto cuando se hace algo arriba de un umbral (dinero)
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'vote_required',
  'Abrir voto para gastos grandes',
  'Cuando se registra un movimiento de dinero por arriba del umbral acordado, se abre una votación grupal en lugar de aprobación unilateral. Útil cuando el grupo prefiere consenso amplio sobre decisiones de gasto importantes.',
  'money', 'approval', array['ledger']::text[],
  jsonb_build_object('threshold_cents', 500000, 'duration_hours', 48, 'quorum_percent', 50, 'threshold_percent', 50),
  jsonb_build_object('trigger_shape_id','ledgerEntryCreated','condition_shape_ids',jsonb_build_array('amountAbove'),'consequence_shape_ids',jsonb_build_array('startVote'),'scope_hint','group'),
  'active', 31,
  'D — Governance',
  array[
    'No es aprobación unilateral (eso es Pedir aprobación antes de una acción)',
    'No castiga (eso es una multa)',
    'No revierte automáticamente — el voto decide'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Familia','label_grupo','Voto para gastos grandes del fondo','params',jsonb_build_object('threshold_cents',300000)),
    jsonb_build_object('vertical','Cenas','label_grupo','Voto para gasto sobre el monto acordado','params',jsonb_build_object('threshold_cents',200000)),
    jsonb_build_object('vertical','Asociación','label_grupo','Voto para movimientos del fondo','params',jsonb_build_object('threshold_cents',2000000)),
    jsonb_build_object('vertical','Coworking','label_grupo','Voto para contratar servicios','params',jsonb_build_object('threshold_cents',1000000)),
    jsonb_build_object('vertical','Roommates','label_grupo','Voto para reparaciones grandes','params',jsonb_build_object('threshold_cents',500000)),
    jsonb_build_object('vertical','Viajes','label_grupo','Voto para pagos a proveedores externos','params',jsonb_build_object('threshold_cents',300000))
  ),
  'Cuando se registre un movimiento mayor a ${{threshold}}, se abre una votación de {{duration_hours}}h.',
  array['same_scope_overlapping']::text[],
  'beta1', array['group','resource','resource_type']::text[],
  array['happy_path_vote_started_above_threshold','below_threshold_no_vote','rule_inactive_no_vote','duplicate_trigger_single_vote','replay_idempotent']::text[]
);

-- =============================================================================
-- 9. transfer_vote_required — voto cuando se transfiere algo grande
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'transfer_vote_required',
  'Voto para transferir un activo valioso',
  'Cuando se transfiere un activo cuya valuación supera un umbral, se abre una votación antes de que la transferencia tenga efecto. Útil para custodias compartidas donde mover algo valioso requiere consenso, no decisión individual.',
  'governance', 'approval', array[]::text[],
  jsonb_build_object('threshold_cents', 5000000, 'duration_hours', 48, 'quorum_percent', 50, 'threshold_percent', 66),
  jsonb_build_object('trigger_shape_id','assetTransferred','condition_shape_ids',jsonb_build_array('transferAmountAbove'),'consequence_shape_ids',jsonb_build_array('startVote'),'scope_hint','resource_type'),
  'active', 32,
  'G — Transfer',
  array[
    'No bloquea transferencias chicas — solo las que superan el umbral',
    'No es aprobación de un admin (eso es Pedir aprobación)',
    'No reversa automáticamente si el voto pierde — el grupo decide qué hacer'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Familia','label_grupo','Voto para transferir el coche familiar','params',jsonb_build_object('threshold_cents',5000000)),
    jsonb_build_object('vertical','Club','label_grupo','Voto para transferir equipo valioso','params',jsonb_build_object('threshold_cents',2000000)),
    jsonb_build_object('vertical','Palco','label_grupo','Voto para transferir el palco','params',jsonb_build_object('threshold_cents',10000000)),
    jsonb_build_object('vertical','Asociación','label_grupo','Voto para transferir activo del fondo','params',jsonb_build_object('threshold_cents',20000000)),
    jsonb_build_object('vertical','Coworking','label_grupo','Voto para transferir mobiliario','params',jsonb_build_object('threshold_cents',1000000)),
    jsonb_build_object('vertical','Roommates','label_grupo','Voto para transferir electrodoméstico','params',jsonb_build_object('threshold_cents',500000))
  ),
  'Cuando se transfiera {{resource.name}} con valuación mayor a ${{threshold}}, se abre una votación de {{duration_hours}}h antes de aplicar.',
  array['same_scope_overlapping']::text[],
  'beta1', array['resource','resource_type']::text[],
  array['happy_path_vote_started_above_threshold','below_threshold_no_vote','rule_inactive_no_vote','replay_idempotent','vote_outcome_recorded']::text[]
);

-- =============================================================================
-- 10. booking_vote_required — voto para reservas largas
-- =============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order,
  doctrinal_category, what_it_is_not, examples_across_verticals,
  natural_language_preview_template_es, conflicts_to_detect, beta_status,
  supported_scopes, tests_required
) values (
  'booking_vote_required',
  'Voto para reservas largas',
  'Cuando alguien crea una reserva que dura más de N minutos, se abre una votación grupal antes de confirmarla. Evita que un miembro monopolice un recurso compartido por mucho tiempo sin consentimiento explícito del grupo.',
  'governance', 'approval', array[]::text[],
  jsonb_build_object('minutes', 120, 'duration_hours', 24, 'quorum_percent', 50, 'threshold_percent', 66),
  jsonb_build_object('trigger_shape_id','bookingCreated','condition_shape_ids',jsonb_build_array('bookingDurationAbove'),'consequence_shape_ids',jsonb_build_array('startVote'),'scope_hint','resource_type'),
  'active', 33,
  'D — Governance',
  array[
    'No bloquea reservas cortas — sólo las que superan el umbral',
    'No cobra (eso es Cobrar por cancelar reserva tarde)',
    'No es aprobación de un admin (eso es Pedir aprobación)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Coworking','label_grupo','Voto para reservas de sala >2h','params',jsonb_build_object('minutes',120)),
    jsonb_build_object('vertical','Club','label_grupo','Voto para uso prolongado de cancha','params',jsonb_build_object('minutes',180)),
    jsonb_build_object('vertical','Palco','label_grupo','Voto para apartar palco varios días','params',jsonb_build_object('minutes',1440)),
    jsonb_build_object('vertical','Familia','label_grupo','Voto para usar coche más de 4h','params',jsonb_build_object('minutes',240)),
    jsonb_build_object('vertical','Asociación','label_grupo','Voto para uso prolongado del local','params',jsonb_build_object('minutes',360)),
    jsonb_build_object('vertical','Viajes','label_grupo','Voto para reservar slot largo','params',jsonb_build_object('minutes',480))
  ),
  'Cuando alguien reserve {{resource.name}} por más de {{minutes}} minutos, se abre una votación de {{duration_hours}}h antes de confirmar.',
  array['same_scope_overlapping']::text[],
  'beta1', array['resource','resource_type']::text[],
  array['happy_path_vote_started_above_duration','below_duration_no_vote','rule_inactive_no_vote','replay_idempotent','vote_outcome_recorded']::text[]
);

-- =============================================================================
-- Re-alias all legacy templates to their trigger-correct universal.
-- =============================================================================

update public.rule_templates set alias_of = 'cancellation_consequence', beta_status = 'post_beta'
 where id = 'cancellation_fee';

update public.rule_templates set alias_of = 'late_return_consequence', beta_status = 'post_beta'
 where id = 'not_returned_fine';

update public.rule_templates set alias_of = 'deadline_consequence', beta_status = 'post_beta'
 where id = 'host_no_menu_fine';

update public.rule_templates set alias_of = 'expiration_warning', beta_status = 'post_beta'
 where id = 'right_expiration_warning';

update public.rule_templates set alias_of = 'booking_cancellation_consequence', beta_status = 'post_beta'
 where id = 'space_cancellation_late_fine';

update public.rule_templates set alias_of = 'damage_approval', beta_status = 'post_beta'
 where id = 'damage_approval_required';

update public.rule_templates set alias_of = 'damage_vote_required', beta_status = 'post_beta'
 where id = 'space_damage_temporary_closure_vote';

update public.rule_templates set alias_of = 'vote_required', beta_status = 'post_beta'
 where id = 'expense_threshold_vote';

update public.rule_templates set alias_of = 'transfer_vote_required', beta_status = 'post_beta'
 where id = 'transfer_large_vote';

update public.rule_templates set alias_of = 'booking_vote_required', beta_status = 'post_beta'
 where id = 'space_long_booking_vote';

-- =============================================================================
-- Sanity counts
-- =============================================================================
do $$
declare
  v_visible int; v_aliased int; v_misaligned int; v_total int;
begin
  select count(*) into v_visible
    from public.rule_templates
   where alias_of is null and beta_status = 'beta1' and status = 'active';
  select count(*) into v_aliased
    from public.rule_templates where alias_of is not null;
  select count(*) into v_misaligned
    from public.rule_templates legacy
    join public.rule_templates universal on universal.id = legacy.alias_of
   where legacy.alias_of is not null
     and legacy.composition->>'trigger_shape_id' <> universal.composition->>'trigger_shape_id';
  select count(*) into v_total from public.rule_templates;
  raise notice 'mig 00325: total=%, visible=%, aliased=%, trigger_misaligned=%',
    v_total, v_visible, v_aliased, v_misaligned;
  if v_visible <> 16 then
    raise warning 'mig 00325: expected 16 visible templates, got %', v_visible;
  end if;
  if v_misaligned <> 0 then
    raise warning 'mig 00325: expected 0 trigger mismatches, got %', v_misaligned;
  end if;
end$$;
