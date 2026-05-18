-- 00296 — Seed 3 universal Beta-1 templates.
--
-- Source: Plans/Active/UniversalRuleTemplates.md §4.1.
-- Doctrine: templates name social/legal patterns (allocation/obligation/
-- governance/…), never verticals. Beta 1 ships the 3 universals that can be
-- composed entirely from shape pieces already catalogued in public.rule_shapes
-- as of mig 00294 — zero new evaluator code, zero new atom types.
--
-- The 3 universals:
--   1. deadline_enforcement          — "Exigir algo antes de una fecha"
--   2. missed_obligation_consequence — "Aplicar consecuencia si alguien no cumple"
--   3. approval_required             — "Pedir aprobación antes de una acción"
--
-- Each composes existing shapes. examples_across_verticals declares 5+
-- coordination patterns where the template applies — the universality test
-- in UniversalRuleTemplates.md §2.1. The composition itself may be narrower
-- than the example set (e.g. approval_required currently composes only the
-- money path because that's the only trigger available); Wave 1 post-Beta
-- will add trigger variants that the same template recomposes via OR.
--
-- Notes:
--   - These templates ship alongside the 12 existing vertical-looking ones.
--     Mig 00297 will alias the verticals to these universals so iOS Gallery
--     stops surfacing the verticals while engine FK resolution keeps working.
--   - `category` (existing column from mig 00181, enum-checked) is set to the
--     closest pre-existing bucket. `doctrinal_category` (new in 00295) holds
--     the canonical universal category from §3 of the plan.

-- =============================================================================
-- 1. deadline_enforcement
-- =============================================================================

insert into public.rule_templates (
  id,
  display_name_es,
  description_es,
  category,
  template_kind,
  required_capabilities,
  default_params,
  composition,
  status,
  sort_order,
  doctrinal_category,
  what_it_is_not,
  examples_across_verticals,
  natural_language_preview_template_es,
  conflicts_to_detect,
  beta_status,
  supported_scopes,
  tests_required
)
values (
  'deadline_enforcement',
  'Exigir algo antes de una fecha',
  'Cuando se acerca una fecha límite y la acción requerida no se ha hecho, el grupo recibe un aviso. Útil para confirmar asistencia, subir documentos, pagar a tiempo, o cualquier obligación con vencimiento.',
  'attendance',
  'behavior',
  array[]::text[],
  jsonb_build_object('hours', 24),
  jsonb_build_object(
    'trigger_shape_id',      'hoursBeforeEvent',
    'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
    'consequence_shape_ids', jsonb_build_array('emitWarning'),
    'scope_hint',            'series'
  ),
  'active',
  10,
  'C — Obligation',
  array[
    'No limita cuántas personas pueden hacerlo (eso es Capacity)',
    'No castiga al que ya incumplió (eso es Consecuencia por incumplir)',
    'No bloquea la acción (eso es Pedir aprobación)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object(
      'vertical',     'Cenas',
      'label_grupo',  'Avisar antes del deadline de RSVP',
      'params',       jsonb_build_object('hours', 24)
    ),
    jsonb_build_object(
      'vertical',     'Fútbol',
      'label_grupo',  'Avisar antes de confirmar lineup',
      'params',       jsonb_build_object('hours', 12)
    ),
    jsonb_build_object(
      'vertical',     'Palco',
      'label_grupo',  'Avisar antes de elegir boletos',
      'params',       jsonb_build_object('hours', 48)
    ),
    jsonb_build_object(
      'vertical',     'Coworking',
      'label_grupo',  'Avisar antes de confirmar reserva',
      'params',       jsonb_build_object('hours', 2)
    ),
    jsonb_build_object(
      'vertical',     'Familia',
      'label_grupo',  'Avisar antes de la comida del sábado',
      'params',       jsonb_build_object('hours', 18)
    ),
    jsonb_build_object(
      'vertical',     'Roommates',
      'label_grupo',  'Avisar antes del pago de renta',
      'params',       jsonb_build_object('hours', 72)
    )
  ),
  'Si {{hours}} horas antes de {{resource.name}} la acción requerida no se ha completado, el grupo recibe un aviso en la actividad.',
  array['same_scope_overlapping','impossible_condition']::text[],
  'beta1',
  array['resource','series','group']::text[],
  array[
    'happy_path_warning_emitted_at_deadline',
    'condition_already_satisfied_no_warning',
    'rule_inactive_no_warning',
    'replay_idempotent_single_warning',
    'multiple_deadlines_same_resource_distinct_warnings'
  ]::text[]
)
on conflict (id) do update set
  display_name_es                       = excluded.display_name_es,
  description_es                        = excluded.description_es,
  category                              = excluded.category,
  template_kind                         = excluded.template_kind,
  required_capabilities                 = excluded.required_capabilities,
  default_params                        = excluded.default_params,
  composition                           = excluded.composition,
  status                                = excluded.status,
  sort_order                            = excluded.sort_order,
  doctrinal_category                    = excluded.doctrinal_category,
  what_it_is_not                        = excluded.what_it_is_not,
  examples_across_verticals             = excluded.examples_across_verticals,
  natural_language_preview_template_es  = excluded.natural_language_preview_template_es,
  conflicts_to_detect                   = excluded.conflicts_to_detect,
  beta_status                           = excluded.beta_status,
  supported_scopes                      = excluded.supported_scopes,
  tests_required                        = excluded.tests_required;

-- =============================================================================
-- 2. missed_obligation_consequence
-- =============================================================================

insert into public.rule_templates (
  id,
  display_name_es,
  description_es,
  category,
  template_kind,
  required_capabilities,
  default_params,
  composition,
  status,
  sort_order,
  doctrinal_category,
  what_it_is_not,
  examples_across_verticals,
  natural_language_preview_template_es,
  conflicts_to_detect,
  beta_status,
  supported_scopes,
  tests_required
)
values (
  'missed_obligation_consequence',
  'Aplicar consecuencia si alguien no cumple',
  'Cuando un miembro no cumple con una obligación (llegar a tiempo, asistir, devolver, pagar), se le aplica una consecuencia configurada — típicamente una multa. Aplica a cualquier obligación con check verificable.',
  'attendance',
  'penalty',
  array['ledger']::text[],
  jsonb_build_object('minutes', 15, 'amount', 200),
  jsonb_build_object(
    'trigger_shape_id',      'checkInRecorded',
    'condition_shape_ids',   jsonb_build_array('checkInMinutesLate'),
    'consequence_shape_ids', jsonb_build_array('fine'),
    'scope_hint',            'series'
  ),
  'active',
  20,
  'C — Obligation',
  array[
    'No avisa antes de que pase (eso es Exigir algo antes de una fecha)',
    'No bloquea la acción (eso es Pedir aprobación)',
    'No reparte cupos (eso es Repartir cupos)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object(
      'vertical',     'Cenas',
      'label_grupo',  'Multa por llegar tarde a la cena',
      'params',       jsonb_build_object('minutes', 15, 'amount', 200)
    ),
    jsonb_build_object(
      'vertical',     'Fútbol',
      'label_grupo',  'Multa por llegar tarde al partido',
      'params',       jsonb_build_object('minutes', 10, 'amount', 100)
    ),
    jsonb_build_object(
      'vertical',     'Palco',
      'label_grupo',  'Multa por no avisar que no vienes',
      'params',       jsonb_build_object('minutes', 30, 'amount', 500)
    ),
    jsonb_build_object(
      'vertical',     'Roommates',
      'label_grupo',  'Multa por no hacer el turno de limpieza',
      'params',       jsonb_build_object('minutes', 60, 'amount', 100)
    ),
    jsonb_build_object(
      'vertical',     'Coworking',
      'label_grupo',  'Cargo por no presentarse a sala reservada',
      'params',       jsonb_build_object('minutes', 30, 'amount', 200)
    ),
    jsonb_build_object(
      'vertical',     'Familia',
      'label_grupo',  'Multa simbólica por llegar tarde a la comida',
      'params',       jsonb_build_object('minutes', 30, 'amount', 50)
    ),
    jsonb_build_object(
      'vertical',     'Viajes',
      'label_grupo',  'Cargo por no cumplir el pago a tiempo',
      'params',       jsonb_build_object('minutes', 1440, 'amount', 500)
    )
  ),
  'Si un miembro llega más de {{minutes}} minutos tarde a {{resource.name}}, se le cobra ${{amount}}.',
  array['same_scope_overlapping','consequence_missing_capability']::text[],
  'beta1',
  array['resource','series']::text[],
  array[
    'happy_path_fine_issued_when_late',
    'within_grace_no_fine',
    'duplicate_check_in_single_fine_idempotent',
    'rule_inactive_no_fine',
    'replay_after_param_change_uses_frozen_version',
    'capability_ledger_missing_blocks_publish'
  ]::text[]
)
on conflict (id) do update set
  display_name_es                       = excluded.display_name_es,
  description_es                        = excluded.description_es,
  category                              = excluded.category,
  template_kind                         = excluded.template_kind,
  required_capabilities                 = excluded.required_capabilities,
  default_params                        = excluded.default_params,
  composition                           = excluded.composition,
  status                                = excluded.status,
  sort_order                            = excluded.sort_order,
  doctrinal_category                    = excluded.doctrinal_category,
  what_it_is_not                        = excluded.what_it_is_not,
  examples_across_verticals             = excluded.examples_across_verticals,
  natural_language_preview_template_es  = excluded.natural_language_preview_template_es,
  conflicts_to_detect                   = excluded.conflicts_to_detect,
  beta_status                           = excluded.beta_status,
  supported_scopes                      = excluded.supported_scopes,
  tests_required                        = excluded.tests_required;

-- =============================================================================
-- 3. approval_required
-- =============================================================================
-- Beta 1 composition wires the money path (ledgerEntryCreated + amountAbove +
-- requireApproval) because that's the trigger surface available today. Wave 1
-- post-Beta will add bookingRequested/transferRequested triggers and the same
-- template will recompose via OR. The universal label and contract are
-- correct as-is; the composition narrows automatically because of the
-- trigger's valid_resource_types.

insert into public.rule_templates (
  id,
  display_name_es,
  description_es,
  category,
  template_kind,
  required_capabilities,
  default_params,
  composition,
  status,
  sort_order,
  doctrinal_category,
  what_it_is_not,
  examples_across_verticals,
  natural_language_preview_template_es,
  conflicts_to_detect,
  beta_status,
  supported_scopes,
  tests_required
)
values (
  'approval_required',
  'Pedir aprobación antes de una acción',
  'Cuando se realiza una acción que supera un umbral acordado, el grupo abre una votación o pide aprobación de un rol específico antes de que tenga efecto. Útil para gastos grandes, transferencias relevantes o decisiones que requieren consenso.',
  'governance',
  'approval',
  array['ledger']::text[],
  jsonb_build_object('threshold_cents', 200000),
  jsonb_build_object(
    'trigger_shape_id',      'ledgerEntryCreated',
    'condition_shape_ids',   jsonb_build_array('amountAbove'),
    'consequence_shape_ids', jsonb_build_array('requireApproval'),
    'scope_hint',            'group'
  ),
  'active',
  30,
  'D — Governance',
  array[
    'No castiga al que ya hizo algo (eso es Consecuencia por incumplir)',
    'No avisa solamente (eso es Exigir algo antes de una fecha)',
    'No reparte cupos (eso es Repartir cupos)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object(
      'vertical',     'Familia',
      'label_grupo',  'Aprobar gastos grandes del fondo común',
      'params',       jsonb_build_object('threshold_cents', 200000)
    ),
    jsonb_build_object(
      'vertical',     'Cenas',
      'label_grupo',  'Aprobar gastos sobre el monto acordado',
      'params',       jsonb_build_object('threshold_cents', 100000)
    ),
    jsonb_build_object(
      'vertical',     'Palco',
      'label_grupo',  'Aprobar transferencias de boletos a externos',
      'params',       jsonb_build_object('threshold_cents', 500000)
    ),
    jsonb_build_object(
      'vertical',     'Roommates',
      'label_grupo',  'Aprobar reparaciones grandes',
      'params',       jsonb_build_object('threshold_cents', 300000)
    ),
    jsonb_build_object(
      'vertical',     'Asociación',
      'label_grupo',  'Aprobar movimientos del fondo',
      'params',       jsonb_build_object('threshold_cents', 1000000)
    ),
    jsonb_build_object(
      'vertical',     'Coworking',
      'label_grupo',  'Aprobar contratación de servicios',
      'params',       jsonb_build_object('threshold_cents', 500000)
    ),
    jsonb_build_object(
      'vertical',     'Viajes',
      'label_grupo',  'Aprobar pagos a proveedores externos',
      'params',       jsonb_build_object('threshold_cents', 300000)
    )
  ),
  'Cuando se registre un movimiento mayor a ${{threshold}}, el grupo deberá aprobarlo antes de que tenga efecto definitivo.',
  array['same_scope_overlapping','approval_loop']::text[],
  'beta1',
  array['group','resource','resource_type']::text[],
  array[
    'happy_path_approval_required_above_threshold',
    'below_threshold_no_approval',
    'rule_inactive_no_approval',
    'duplicate_trigger_single_approval_idempotent',
    'approval_loop_blocks_publish'
  ]::text[]
)
on conflict (id) do update set
  display_name_es                       = excluded.display_name_es,
  description_es                        = excluded.description_es,
  category                              = excluded.category,
  template_kind                         = excluded.template_kind,
  required_capabilities                 = excluded.required_capabilities,
  default_params                        = excluded.default_params,
  composition                           = excluded.composition,
  status                                = excluded.status,
  sort_order                            = excluded.sort_order,
  doctrinal_category                    = excluded.doctrinal_category,
  what_it_is_not                        = excluded.what_it_is_not,
  examples_across_verticals             = excluded.examples_across_verticals,
  natural_language_preview_template_es  = excluded.natural_language_preview_template_es,
  conflicts_to_detect                   = excluded.conflicts_to_detect,
  beta_status                           = excluded.beta_status,
  supported_scopes                      = excluded.supported_scopes,
  tests_required                        = excluded.tests_required;
