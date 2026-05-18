-- 00268 — Space rule shapes (Plans/Active/SpaceRules.md §3).
--
-- Registers the trigger / condition / consequence shape pieces the
-- Beta 1 Rule Builder needs to compose space-specific rules. The 7
-- canonical templates (`space_capacity_overflow_waitlist`,
-- `space_cancellation_late_fine`, `space_no_check_in_release`,
-- `space_outside_allowed_hours_deny`, `space_founder_priority_bump`,
-- `space_long_booking_vote`, `space_damage_temporary_closure_vote`)
-- seed in a follow-up migration — this migration ships ONLY the catalog
-- rows so the Builder gallery can render the chips and the rule engine
-- can find the corresponding evaluators by id.
--
-- Pieces added (per SpaceRules.md §3):
--
--   triggers (5 new):
--     spaceCapacityReached    — `spaceCapacityReached` emitted by book_space
--     bookingCancelled        — `bookingCancelled` emitted by cancel_booking
--     bookingNoCheckIn        — synthetic, emitted by future
--                               emit-space-no-check-in-events cron (PR-2)
--     bookingCreated          — `bookingCreated` emitted by book_space
--                               (scoped to space target_kind via condition)
--     spaceWaitlistJoined     — `spaceWaitlistJoined` emitted by join_waitlist
--
--   conditions (5 new):
--     cancelledWithinHours    — payload.starts_at - now() < hours
--     outsideAllowedHours     — now().hour < start OR now().hour >= end
--     actorHasRole            — member.roles ? role
--     bookingDurationAbove    — ends_at - starts_at > minutes
--     damageSeverityAbove     — severity >= level (asset spec reuse, but
--                               registered here for space too via shape)
--
--   consequences (3 new):
--     releaseBooking          — calls expire_booking(reason='no_check_in')
--     denyAction              — blocks the trigger action (booking, etc.)
--     bumpPriority            — modifies payload.priority on next
--                               spaceWaitlistJoined row for actor
--
-- All entries use the same INSERT/ON CONFLICT shape as mig 00226 so
-- re-runs are idempotent. iOS reads these via `list_rule_shapes()`.
--
-- The engine evaluators that consume these shape ids live in
-- supabase/functions/_shared/ruleEngine.ts (extended in PR-3 of the
-- SpaceRules roadmap). Without those evaluators a rule composed from
-- these shapes parses fine but produces zero effects — the catalog row
-- is the metadata, the evaluator is the behavior. PR-1 ships the
-- metadata so the Builder UI can render templates as previewable
-- chips even before the engine learns to fire them.

-- =============================================================================
-- 1. Trigger shapes (5 new)
-- =============================================================================

insert into public.rule_shapes (
  id, kind, label_es, summary_es, icon,
  valid_scopes, valid_resource_types, config_fields, sort_order
) values
  ('spaceCapacityReached',
   'trigger',
   'Cuando el espacio llega al aforo',
   'Se dispara cuando una reserva completa el aforo del espacio. El payload trae la capacidad y la reserva que disparó el evento.',
   'person.3.fill',
   array['resource','resource_type','group']::text[],
   array['space']::text[],
   '[]'::jsonb,
   300),
  ('bookingCancelled',
   'trigger',
   'Cuando alguien cancela una reserva',
   'Se dispara cada vez que un booking se cancela manualmente. El payload trae quién canceló y la razón.',
   'xmark.circle',
   array['resource','resource_type','group']::text[],
   array['space','slot']::text[],
   '[]'::jsonb,
   310),
  ('bookingNoCheckIn',
   'trigger',
   'Cuando nadie marcó llegada a tiempo',
   'Se dispara cuando una reserva pasa su hora de inicio sin que nadie haya hecho check-in. Configura los minutos de tolerancia.',
   'clock.badge.xmark',
   array['resource','resource_type','group']::text[],
   array['space']::text[],
   '[{"key":"grace_minutes","kind":"int","label_es":"Tolerancia (min)","placeholder":"30","min":0,"max":240,"defaultValue":30}]'::jsonb,
   320),
  ('bookingCreated',
   'trigger',
   'Cuando alguien hace una reserva',
   'Se dispara al crear un nuevo booking sobre el espacio. Útil para validar horarios permitidos o requerir voto en reservas largas.',
   'calendar.badge.plus',
   array['resource','resource_type','group']::text[],
   array['space','slot']::text[],
   '[]'::jsonb,
   330),
  ('spaceWaitlistJoined',
   'trigger',
   'Cuando alguien entra a la lista de espera',
   'Se dispara cada vez que un miembro se suma a la cola del espacio. Útil para subir prioridad a fundadores o miembros premium.',
   'person.crop.circle.badge.clock',
   array['resource','resource_type','group']::text[],
   array['space']::text[],
   '[]'::jsonb,
   340)
on conflict (id) do update set
  label_es = excluded.label_es,
  summary_es = excluded.summary_es,
  icon = excluded.icon,
  valid_scopes = excluded.valid_scopes,
  valid_resource_types = excluded.valid_resource_types,
  config_fields = excluded.config_fields,
  sort_order = excluded.sort_order;

-- =============================================================================
-- 2. Condition shapes (5 new)
-- =============================================================================

insert into public.rule_shapes (
  id, kind, label_es, summary_es, icon,
  valid_scopes, valid_resource_types, config_fields, sort_order
) values
  ('cancelledWithinHours',
   'condition',
   'Solo si cancelan con menos de X horas',
   'Filtra para que la regla aplique únicamente cuando la cancelación ocurre dentro de la ventana previa al inicio de la reserva.',
   'clock.arrow.circlepath',
   array[]::text[],
   array[]::text[],
   '[{"key":"hours","kind":"int","label_es":"Horas antes del inicio","placeholder":"24","min":1,"max":168,"defaultValue":24}]'::jsonb,
   300),
  ('outsideAllowedHours',
   'condition',
   'Solo fuera del horario permitido',
   'Filtra para que la regla aplique cuando la reserva cae fuera de un rango horario del día. Por ejemplo, bloquear bookings nocturnos.',
   'moon.zzz',
   array[]::text[],
   array[]::text[],
   '[{"key":"start_hour","kind":"int","label_es":"Hora de apertura (24h)","placeholder":"8","min":0,"max":23,"defaultValue":8},{"key":"end_hour","kind":"int","label_es":"Hora de cierre (24h)","placeholder":"22","min":1,"max":24,"defaultValue":22}]'::jsonb,
   310),
  ('actorHasRole',
   'condition',
   'Solo si el actor tiene cierto rol',
   'Filtra por el rol del miembro que disparó la acción. Útil para dar prioridad a founders o admins, o restringir a tesoreros.',
   'person.text.rectangle',
   array[]::text[],
   array[]::text[],
   '[{"key":"role","kind":"text","label_es":"Rol requerido","placeholder":"founder","defaultValue":"founder"}]'::jsonb,
   320),
  ('bookingDurationAbove',
   'condition',
   'Solo si la reserva dura más de X minutos',
   'Filtra para que la regla aplique únicamente cuando la duración de la reserva (ends_at − starts_at) supera el umbral.',
   'timer',
   array[]::text[],
   array[]::text[],
   '[{"key":"minutes","kind":"int","label_es":"Duración mínima (min)","placeholder":"120","min":15,"max":1440,"defaultValue":120}]'::jsonb,
   330),
  ('damageSeverityAbove',
   'condition',
   'Solo si la severidad del daño supera X',
   'Filtra el atom de damage por nivel mínimo de severidad (minor < moderate < major < total).',
   'exclamationmark.octagon',
   array[]::text[],
   array[]::text[],
   '[{"key":"level","kind":"text","label_es":"Nivel mínimo","placeholder":"major","defaultValue":"major"}]'::jsonb,
   340)
on conflict (id) do update set
  label_es = excluded.label_es,
  summary_es = excluded.summary_es,
  icon = excluded.icon,
  valid_scopes = excluded.valid_scopes,
  valid_resource_types = excluded.valid_resource_types,
  config_fields = excluded.config_fields,
  sort_order = excluded.sort_order;

-- =============================================================================
-- 3. Consequence shapes (3 new)
-- =============================================================================

insert into public.rule_shapes (
  id, kind, label_es, summary_es, icon,
  valid_scopes, valid_resource_types, config_fields, sort_order
) values
  ('releaseBooking',
   'consequence',
   'Liberar la reserva',
   'Cierra la reserva actual emitiendo `bookingExpired` + `spaceReleased`. Útil para auto-liberar cuando nadie hace check-in.',
   'arrow.uturn.backward.circle',
   array[]::text[],
   array['space']::text[],
   '[{"key":"reason","kind":"text","label_es":"Razón","placeholder":"no_check_in","defaultValue":"no_check_in"}]'::jsonb,
   200),
  ('denyAction',
   'consequence',
   'Rechazar la acción',
   'Bloquea la acción que disparó la regla (por ejemplo, una reserva fuera del horario permitido). Devuelve error al usuario para que decida explícitamente qué hacer.',
   'hand.raised.slash',
   array[]::text[],
   array[]::text[],
   '[{"key":"message_es","kind":"text","label_es":"Mensaje al usuario","placeholder":"Esta acción no está permitida en este horario","defaultValue":"Esta acción no está permitida"}]'::jsonb,
   210),
  ('bumpPriority',
   'consequence',
   'Subir prioridad del miembro',
   'Aumenta la prioridad del miembro en la próxima lista de espera del espacio. Útil para dar ventaja a founders o miembros premium.',
   'arrow.up.circle',
   array[]::text[],
   array['space']::text[],
   '[{"key":"priority_delta","kind":"int","label_es":"Incremento de prioridad","placeholder":"100","min":1,"max":1000,"defaultValue":100}]'::jsonb,
   220)
on conflict (id) do update set
  label_es = excluded.label_es,
  summary_es = excluded.summary_es,
  icon = excluded.icon,
  valid_scopes = excluded.valid_scopes,
  valid_resource_types = excluded.valid_resource_types,
  config_fields = excluded.config_fields,
  sort_order = excluded.sort_order;

comment on table public.rule_shapes is
  'Catalog of rule shape pieces (triggers/conditions/consequences). Mig 00268 added 5 space triggers + 5 space conditions + 3 space consequences (Plans/Active/SpaceRules.md §3). Read via list_rule_shapes() RPC; the iOS Rule Builder renders each row as a chip in the form.';
