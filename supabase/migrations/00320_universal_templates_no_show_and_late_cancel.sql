-- 00320 — Seed 2 more universal Beta-1 templates + re-alias legacy mappings.
--
-- Source: Plans/Active/UniversalRuleTemplates.md §14 (Fase 2 — pipeline
-- convergence). Continues 00296/00297.
--
-- Background: mig 00297 aliased `no_show_fine` and `same_day_cancel_fine`
-- to `missed_obligation_consequence`. That worked for Gallery filtering
-- but lost trigger semantics — the universal composes `checkInRecorded`,
-- not `eventClosed` / `rsvpChangedSameDay`. New rules published via the
-- alias only fire on late check-in, not on no-show or same-day cancel.
--
-- This mig closes the gap by shipping 2 sibling universals — same C —
-- Obligation category, different trigger pieces — so Beta-1 users get
-- end-to-end coverage of the 3 common attendance patterns:
--
--   1. missed_obligation_consequence   (existing) — late check-in → fine
--   2. no_show_consequence             (NEW)      — event closed without check-in → fine
--   3. late_cancellation_consequence   (NEW)      — same-day cancel within X hours → fine
--
-- All universal: each declares ≥5 verticales (cenas, fútbol, palco,
-- coworking, roommates, familia, viajes). Schema still single-trigger
-- per composition — pipeline that supports OR triggers is post-Beta.
--
-- Re-aliasing: no_show_fine → no_show_consequence, same_day_cancel_fine
-- → late_cancellation_consequence. Existing rule_versions FK-resolved by
-- template_id keep working; Gallery filter is unchanged.
--
-- Composes only existing shape pieces (00084: rsvpChangedSameDay,
-- eventClosed, cancelledWithinHours, fine, alwaysTrue). Zero evaluator
-- code in ruleEngine.ts.

-- =============================================================================
-- 1. no_show_consequence
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
  'no_show_consequence',
  'Cobrar a quien no llegó',
  'Cuando el evento cierre y un miembro no haya hecho check-in (estuvo confirmado pero no apareció), se le cobra una multa. Aplica a cenas, partidos, palcos, salas reservadas, comidas familiares, reuniones.',
  'attendance',
  'penalty',
  array['ledger']::text[],
  jsonb_build_object('amount', 250),
  jsonb_build_object(
    'trigger_shape_id',      'eventClosed',
    'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
    'consequence_shape_ids', jsonb_build_array('fine'),
    'scope_hint',            'series'
  ),
  'active',
  21,
  'C — Obligation',
  array[
    'No castiga al que llegó tarde (eso es Aplicar consecuencia si alguien no cumple)',
    'No castiga al que avisó con anticipación que no venía (eso es Cancelación tardía)',
    'No bloquea futuras participaciones (eso es Restringir acceso)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Cenas','label_grupo','Multa por no llegar a la cena','params',jsonb_build_object('amount',200)),
    jsonb_build_object('vertical','Fútbol','label_grupo','Multa por no llegar al partido','params',jsonb_build_object('amount',150)),
    jsonb_build_object('vertical','Palco','label_grupo','Multa por no usar el boleto','params',jsonb_build_object('amount',500)),
    jsonb_build_object('vertical','Coworking','label_grupo','Cargo por no presentarse','params',jsonb_build_object('amount',300)),
    jsonb_build_object('vertical','Familia','label_grupo','Multa simbólica por no llegar a la comida','params',jsonb_build_object('amount',100)),
    jsonb_build_object('vertical','Asociación','label_grupo','Multa por faltar a la reunión','params',jsonb_build_object('amount',400)),
    jsonb_build_object('vertical','Viajes','label_grupo','Cargo por no presentarse al viaje','params',jsonb_build_object('amount',1000))
  ),
  'Si un miembro confirmó asistencia a {{resource.name}} pero el evento cierra sin su check-in, se le cobra ${{amount}}.',
  array['same_scope_overlapping','consequence_missing_capability']::text[],
  'beta1',
  array['resource','series']::text[],
  array[
    'happy_path_fine_issued_on_event_close_without_checkin',
    'attended_no_fine',
    'rule_inactive_no_fine',
    'event_reopened_no_double_fine',
    'replay_idempotent_single_fine',
    'capability_ledger_missing_blocks_publish'
  ]::text[]
)
on conflict (id) do update set
  display_name_es = excluded.display_name_es,
  description_es = excluded.description_es,
  category = excluded.category,
  template_kind = excluded.template_kind,
  required_capabilities = excluded.required_capabilities,
  default_params = excluded.default_params,
  composition = excluded.composition,
  status = excluded.status,
  sort_order = excluded.sort_order,
  doctrinal_category = excluded.doctrinal_category,
  what_it_is_not = excluded.what_it_is_not,
  examples_across_verticals = excluded.examples_across_verticals,
  natural_language_preview_template_es = excluded.natural_language_preview_template_es,
  conflicts_to_detect = excluded.conflicts_to_detect,
  beta_status = excluded.beta_status,
  supported_scopes = excluded.supported_scopes,
  tests_required = excluded.tests_required;

-- =============================================================================
-- 2. late_cancellation_consequence
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
  'late_cancellation_consequence',
  'Cobrar por cancelar tarde',
  'Cuando un miembro cancela su asistencia con menos de N horas de anticipación, se le cobra una multa. Reconoce el costo logístico de cancelar a última hora: cupos perdidos, comida planeada, recursos asignados.',
  'attendance',
  'penalty',
  array['ledger']::text[],
  jsonb_build_object('hours', 24, 'amount', 150),
  jsonb_build_object(
    'trigger_shape_id',      'rsvpChangedSameDay',
    'condition_shape_ids',   jsonb_build_array('cancelledWithinHours'),
    'consequence_shape_ids', jsonb_build_array('fine'),
    'scope_hint',            'series'
  ),
  'active',
  22,
  'C — Obligation',
  array[
    'No castiga al que no apareció sin avisar (eso es Cobrar a quien no llegó)',
    'No castiga al que llegó tarde (eso es Aplicar consecuencia si alguien no cumple)',
    'No castiga al que cancela con suficiente anticipación'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Cenas','label_grupo','Multa por cancelar el mismo día','params',jsonb_build_object('hours',24,'amount',150)),
    jsonb_build_object('vertical','Fútbol','label_grupo','Multa por cancelar a última hora','params',jsonb_build_object('hours',12,'amount',100)),
    jsonb_build_object('vertical','Palco','label_grupo','Multa por cancelar boleto mismo día','params',jsonb_build_object('hours',24,'amount',300)),
    jsonb_build_object('vertical','Coworking','label_grupo','Cargo por cancelar reserva tarde','params',jsonb_build_object('hours',2,'amount',200)),
    jsonb_build_object('vertical','Familia','label_grupo','Multa por cancelar la comida tarde','params',jsonb_build_object('hours',18,'amount',50)),
    jsonb_build_object('vertical','Asociación','label_grupo','Multa por avisar tarde','params',jsonb_build_object('hours',48,'amount',500)),
    jsonb_build_object('vertical','Viajes','label_grupo','Cargo por cancelar a última hora','params',jsonb_build_object('hours',72,'amount',2000))
  ),
  'Si un miembro cancela su asistencia a {{resource.name}} con menos de {{hours}} horas de anticipación, se le cobra ${{amount}}.',
  array['same_scope_overlapping','consequence_missing_capability']::text[],
  'beta1',
  array['resource','series']::text[],
  array[
    'happy_path_fine_issued_when_cancel_within_window',
    'cancelled_before_window_no_fine',
    'rule_inactive_no_fine',
    'duplicate_cancel_single_fine_idempotent',
    'cancel_then_reattend_no_lingering_fine',
    'capability_ledger_missing_blocks_publish'
  ]::text[]
)
on conflict (id) do update set
  display_name_es = excluded.display_name_es,
  description_es = excluded.description_es,
  category = excluded.category,
  template_kind = excluded.template_kind,
  required_capabilities = excluded.required_capabilities,
  default_params = excluded.default_params,
  composition = excluded.composition,
  status = excluded.status,
  sort_order = excluded.sort_order,
  doctrinal_category = excluded.doctrinal_category,
  what_it_is_not = excluded.what_it_is_not,
  examples_across_verticals = excluded.examples_across_verticals,
  natural_language_preview_template_es = excluded.natural_language_preview_template_es,
  conflicts_to_detect = excluded.conflicts_to_detect,
  beta_status = excluded.beta_status,
  supported_scopes = excluded.supported_scopes,
  tests_required = excluded.tests_required;

-- =============================================================================
-- 3. Re-alias legacy templates to the correct trigger-variant universal.
-- =============================================================================
-- Previous alias (mig 00297): both pointed at missed_obligation_consequence
-- which used checkInRecorded — wrong semantics. Repoint to the trigger
-- variants seeded above. status stays 'active' so engine FK keeps working
-- for existing rule_versions; beta_status='post_beta' keeps them out of
-- the Gallery.

update public.rule_templates
   set alias_of    = 'no_show_consequence',
       beta_status = 'post_beta'
 where id = 'no_show_fine';

update public.rule_templates
   set alias_of    = 'late_cancellation_consequence',
       beta_status = 'post_beta'
 where id = 'same_day_cancel_fine';

-- =============================================================================
-- Sanity counts
-- =============================================================================
do $$
declare
  v_visible int;
  v_aliased int;
begin
  select count(*) into v_visible
    from public.rule_templates
   where alias_of is null and beta_status = 'beta1' and status = 'active';
  select count(*) into v_aliased
    from public.rule_templates where alias_of is not null;
  raise notice 'mig 00320: visible=%, aliased=%', v_visible, v_aliased;
  -- Expect: visible was 3, now 5 (added 2 universals). aliased was 14, now still 14 (just repointed).
  if v_visible <> 5 then
    raise warning 'mig 00320: expected 5 visible templates, got %', v_visible;
  end if;
end$$;
