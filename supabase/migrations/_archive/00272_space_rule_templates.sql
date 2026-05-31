-- 00272 — Space rule templates (Plans/Active/SpaceRules.md §1).
--
-- Seeds the 7 canonical space rule templates the Space.md §18 spec
-- promised. Each composes shape pieces from mig 00268 with existing
-- reusable pieces (`alwaysTrue`, `fine`, `startVote`, `emitWarning`).
--
-- Constraint extension
-- ====================
-- `rule_templates_category_check` (mig 00227 extended it with
-- 'assets'). This mig adds 'spaces' so space templates cluster in
-- their own gallery section without leaking into 'allocation' or
-- 'governance'. The mig drops + re-adds the constraint with 'spaces'
-- appended before inserting the new rows.
--
-- Templates (per SpaceRules.md §1):
--
--   space_capacity_overflow_waitlist     spaceCapacityReached + alwaysTrue + emitWarning
--   space_cancellation_late_fine         bookingCancelled + cancelledWithinHours + fine
--   space_no_check_in_release            bookingNoCheckIn + alwaysTrue + releaseBooking
--   space_outside_allowed_hours_deny     bookingCreated + outsideAllowedHours + denyAction
--   space_founder_priority_bump          spaceWaitlistJoined + actorHasRole + bumpPriority
--   space_long_booking_vote              bookingCreated + bookingDurationAbove + startVote
--   space_damage_temporary_closure_vote  damageReported + damageSeverityAbove + startVote
--
-- Each `required_capabilities` array gates the template's visibility in
-- the iOS Rule Builder gallery to spaces that have those capabilities
-- enabled (filter is client-side; the catalog ships every template).

alter table public.rule_templates
  drop constraint rule_templates_category_check;

alter table public.rule_templates
  add constraint rule_templates_category_check
    check (category = any (array[
      'attendance'::text,
      'money'::text,
      'allocation'::text,
      'governance'::text,
      'custody'::text,
      'assets'::text,
      'spaces'::text,
      'other'::text
    ]));

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order
) values
  (
    'space_capacity_overflow_waitlist',
    'Avisa cuando el espacio se llena',
    'Cuando una reserva completa el aforo del espacio, emite un aviso visible en la actividad. La UI sugiere a los siguientes interesados unirse a la lista de espera.',
    'spaces',
    'governance',
    array['capacity']::text[],
    jsonb_build_object(),
    jsonb_build_object(
      'trigger_shape_id',      'spaceCapacityReached',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('emitWarning'),
      'scope_hint',            'resource'
    ),
    'active',
    200
  ),
  (
    'space_cancellation_late_fine',
    'Multa por cancelación tardía',
    'Si alguien cancela una reserva con menos de X horas antes de su inicio, cobra una multa. Justo cuando ya no hay tiempo para que otro miembro use el espacio.',
    'spaces',
    'penalty',
    array['booking','consequence']::text[],
    jsonb_build_object('hours', 24, 'amount', 200),
    jsonb_build_object(
      'trigger_shape_id',      'bookingCancelled',
      'condition_shape_ids',   jsonb_build_array('cancelledWithinHours'),
      'consequence_shape_ids', jsonb_build_array('fine'),
      'scope_hint',            'resource'
    ),
    'active',
    210
  ),
  (
    'space_no_check_in_release',
    'Libera la reserva si nadie marca llegada',
    'Si pasa la hora de inicio y nadie ha hecho check-in en los siguientes X minutos, libera automáticamente la reserva para que otro miembro pueda ocupar el espacio.',
    'spaces',
    'governance',
    array['booking','check_in']::text[],
    jsonb_build_object('grace_minutes', 30),
    jsonb_build_object(
      'trigger_shape_id',      'bookingNoCheckIn',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('releaseBooking'),
      'scope_hint',            'resource'
    ),
    'active',
    220
  ),
  (
    'space_outside_allowed_hours_deny',
    'Rechaza reservas fuera del horario',
    'Si alguien intenta reservar fuera del horario permitido (por ejemplo, fuera de 8am-10pm), el sistema lo marca como no permitido. La UI captura el rechazo y avisa al usuario.',
    'spaces',
    'governance',
    array['booking','schedule']::text[],
    jsonb_build_object(
      'start_hour', 8,
      'end_hour',   22,
      'message_es', 'Reservas solo dentro del horario permitido del espacio'
    ),
    jsonb_build_object(
      'trigger_shape_id',      'bookingCreated',
      'condition_shape_ids',   jsonb_build_array('outsideAllowedHours'),
      'consequence_shape_ids', jsonb_build_array('denyAction'),
      'scope_hint',            'resource'
    ),
    'active',
    230
  ),
  (
    'space_founder_priority_bump',
    'Fundadores tienen prioridad en lista de espera',
    'Cuando un fundador entra a la lista de espera, su prioridad sube automáticamente para que pase delante de bookings posteriores. Para miembros con otro rol, configura el campo "rol".',
    'spaces',
    'governance',
    array['waitlist']::text[],
    jsonb_build_object('role', 'founder', 'priority_delta', 100),
    jsonb_build_object(
      'trigger_shape_id',      'spaceWaitlistJoined',
      'condition_shape_ids',   jsonb_build_array('actorHasRole'),
      'consequence_shape_ids', jsonb_build_array('bumpPriority'),
      'scope_hint',            'resource'
    ),
    'active',
    240
  ),
  (
    'space_long_booking_vote',
    'Reservas largas requieren voto',
    'Si alguien reserva el espacio por más de X minutos en una sola sesión, abre automáticamente una votación al grupo. Útil para gates de uso intensivo (ej. canchas, palco).',
    'spaces',
    'governance',
    array['booking','voting']::text[],
    jsonb_build_object(
      'minutes',           120,
      'duration_hours',    24,
      'quorum_percent',    50,
      'threshold_percent', 66
    ),
    jsonb_build_object(
      'trigger_shape_id',      'bookingCreated',
      'condition_shape_ids',   jsonb_build_array('bookingDurationAbove'),
      'consequence_shape_ids', jsonb_build_array('startVote'),
      'scope_hint',            'resource'
    ),
    'active',
    250
  ),
  (
    'space_damage_temporary_closure_vote',
    'Daño grave: voto para cerrar temporalmente el espacio',
    'Si alguien reporta un daño con severidad grave o total, abre automáticamente una votación al grupo para decidir si cerrar temporalmente el espacio mientras se repara.',
    'spaces',
    'governance',
    array['maintenance','voting']::text[],
    jsonb_build_object(
      'level',             'major',
      'duration_hours',    48,
      'quorum_percent',    50,
      'threshold_percent', 66
    ),
    jsonb_build_object(
      'trigger_shape_id',      'damageReported',
      'condition_shape_ids',   jsonb_build_array('damageSeverityAbove'),
      'consequence_shape_ids', jsonb_build_array('startVote'),
      'scope_hint',            'resource'
    ),
    'active',
    260
  )
on conflict (id) do update set
  display_name_es       = excluded.display_name_es,
  description_es        = excluded.description_es,
  category              = excluded.category,
  template_kind         = excluded.template_kind,
  required_capabilities = excluded.required_capabilities,
  default_params        = excluded.default_params,
  composition           = excluded.composition,
  status                = excluded.status,
  sort_order            = excluded.sort_order;

comment on table public.rule_templates is
  'Curated rule template catalog. Mig 00272 added 7 canonical space templates under category=spaces (Plans/Active/SpaceRules.md §1) + extended rule_templates_category_check to include spaces. Read via list_rule_templates() RPC. iOS mirror lives in MockRuleTemplateRepository.defaultBetaCatalog for previews + offline.';
