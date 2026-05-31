-- 00321 — Seed `no_rsvp_consequence` universal + re-alias no_rsvp_fine.
--
-- Source: Plans/Active/UniversalRuleTemplates.md §14 Fase 2.
-- Continuation of the alias-audit cleanup started in mig 00320.
--
-- Audit finding (2026-05-18): of 14 legacy templates with alias_of set
-- post mig 00297/00320, 9 still have trigger semantics that diverge from
-- their alias target. The same bug class as the no_show/late_cancel fix
-- — Gallery picks publish rules with the wrong trigger.
--
-- This mig closes one more gap (the highest-traffic one for Beta-1
-- attendance flows): `no_rsvp_fine` was aliased to
-- missed_obligation_consequence (checkInRecorded), but legacy fires on
-- `rsvpDeadlinePassed` — "deadline passed without explicit RSVP".
-- Universal pattern: someone failed to acknowledge an obligation by
-- its deadline → consequence. Universal across cenas (RSVP), familia
-- (comida sí/no), coworking (reserva confirmada), asociación
-- (asistencia declarada), viajes (compromiso).
--
-- Remaining 8 mismatches deferred to a Wave-1 batch with explicit
-- product review (cancellation_fee, host_no_menu_fine, not_returned_fine,
-- right_expiration_warning, space_cancellation_late_fine,
-- damage_approval_required, space_long_booking_vote, transfer_large_vote,
-- space_damage_temporary_closure_vote). Each needs either a sibling
-- universal or naming-cleanup promotion — see plan §14.

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
  'no_rsvp_consequence',
  'Cobrar al que no avisó',
  'Cuando se vence la fecha límite para confirmar asistencia y un miembro nunca contestó (ni sí ni no), se le cobra una multa. Reconoce el costo de no saber con cuántos contar: comida planeada, recursos reservados, espacios apartados.',
  'attendance',
  'penalty',
  array['ledger']::text[],
  jsonb_build_object('amount', 100),
  jsonb_build_object(
    'trigger_shape_id',      'rsvpDeadlinePassed',
    'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
    'consequence_shape_ids', jsonb_build_array('fine'),
    'scope_hint',            'series'
  ),
  'active',
  23,
  'C — Obligation',
  array[
    'No castiga al que dijo "no voy" a tiempo (eso es OK; el grupo ya sabe que no cuenta con él)',
    'No castiga al que llegó tarde (eso es Aplicar consecuencia si alguien no cumple)',
    'No castiga al que no apareció habiendo dicho "sí voy" (eso es Cobrar a quien no llegó)'
  ]::text[],
  jsonb_build_array(
    jsonb_build_object('vertical','Cenas','label_grupo','Multa por no avisar si venías a la cena','params',jsonb_build_object('amount',100)),
    jsonb_build_object('vertical','Fútbol','label_grupo','Multa por no confirmar si jugabas','params',jsonb_build_object('amount',50)),
    jsonb_build_object('vertical','Palco','label_grupo','Multa por no responder si usabas tu lugar','params',jsonb_build_object('amount',200)),
    jsonb_build_object('vertical','Familia','label_grupo','Multa simbólica por no avisar a la comida','params',jsonb_build_object('amount',50)),
    jsonb_build_object('vertical','Coworking','label_grupo','Cargo por no confirmar la reserva','params',jsonb_build_object('amount',150)),
    jsonb_build_object('vertical','Asociación','label_grupo','Multa por no confirmar asistencia a la reunión','params',jsonb_build_object('amount',200)),
    jsonb_build_object('vertical','Viajes','label_grupo','Cargo por no confirmar si vienes al viaje','params',jsonb_build_object('amount',500))
  ),
  'Si un miembro no responde "sí" ni "no" antes del deadline de RSVP de {{resource.name}}, se le cobra ${{amount}}.',
  array['same_scope_overlapping','consequence_missing_capability']::text[],
  'beta1',
  array['resource','series']::text[],
  array[
    'happy_path_fine_issued_at_rsvp_deadline_when_no_response',
    'responded_yes_no_fine',
    'responded_no_no_fine',
    'rule_inactive_no_fine',
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

-- Re-alias the legacy to the trigger-correct universal.
update public.rule_templates
   set alias_of    = 'no_rsvp_consequence',
       beta_status = 'post_beta'
 where id = 'no_rsvp_fine';

do $$
declare v_visible int; v_aliased int; v_misaligned int;
begin
  select count(*) into v_visible
    from public.rule_templates
   where alias_of is null and beta_status = 'beta1' and status = 'active';
  select count(*) into v_aliased
    from public.rule_templates where alias_of is not null;
  -- Count aliases whose trigger still doesn't match their target.
  select count(*) into v_misaligned
    from public.rule_templates legacy
    join public.rule_templates universal on universal.id = legacy.alias_of
   where legacy.alias_of is not null
     and legacy.composition->>'trigger_shape_id' <> universal.composition->>'trigger_shape_id';
  raise notice 'mig 00321: visible=%, aliased=%, trigger_misaligned=%',
    v_visible, v_aliased, v_misaligned;
end$$;
