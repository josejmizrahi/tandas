-- 00072 — Seed `modules.basic_fines.provided_rules_def` with the 5
-- dinner rule definitions.
--
-- Phase A step 2 of the L1 rules-architecture refactor (audit doc:
-- Plans/Active/L1_Audit_2026-05-10.md, Hallazgo 1).
--
-- The 5 fine rules currently live in three duplicated places:
--   1. `templates.config.defaultRules` (jsonb, mig 00038 reconciled)
--   2. `seed_dinner_template_rules` SQL body (mig 00058)
--   3. `DinnerRecurringTemplate.defaultRules(groupId:)` Swift factory
--
-- After this migration, `modules.basic_fines.provided_rules_def` is the
-- canonical source. Subsequent migrations will:
--   - 00073 add seed_module_rules / archive_module_rules RPCs that read
--     from this column.
--   - 00074 wire set_group_module to call seed/archive on toggle.
--   - 00075 backfill module_key on existing groups' rule rows.
--
-- Idempotency: uses `update ... where id = 'basic_fines'`. Safe to
-- re-run; overwrites whatever was there.

update public.modules
set provided_rules_def = jsonb_build_array(
  -- Rule 1 — Llegada tardía (escalating fine)
  jsonb_build_object(
    'slug',         'dinner_late_arrival',
    'name',         'Llegada tardía',
    'description',  'Multa escalada por minuto de retraso al check-in.',
    'isActive',     true,
    'trigger',      jsonb_build_object(
                      'eventType', 'checkInRecorded',
                      'config',    '{}'::jsonb
                    ),
    'conditions',   jsonb_build_array(
                      jsonb_build_object(
                        'type',   'checkInMinutesLate',
                        'config', jsonb_build_object('thresholdMinutes', 0)
                      )
                    ),
    'consequences', jsonb_build_array(
                      jsonb_build_object(
                        'type',   'fine',
                        'config', jsonb_build_object(
                          'baseAmount',  200,
                          'stepAmount',  50,
                          'stepMinutes', 30
                        )
                      )
                    )
  ),
  -- Rule 2 — No confirmó a tiempo
  jsonb_build_object(
    'slug',         'dinner_no_response',
    'name',         'No confirmó a tiempo',
    'description',  'Multa por no responder RSVP antes del cierre del evento.',
    'isActive',     true,
    'trigger',      jsonb_build_object(
                      'eventType', 'eventClosed',
                      'config',    '{}'::jsonb
                    ),
    'conditions',   jsonb_build_array(
                      jsonb_build_object(
                        'type',   'responseStatusIs',
                        'config', jsonb_build_object('status', 'pending')
                      )
                    ),
    'consequences', jsonb_build_array(
                      jsonb_build_object(
                        'type',   'fine',
                        'config', jsonb_build_object('amount', 200)
                      )
                    )
  ),
  -- Rule 3 — Cancelación mismo día
  jsonb_build_object(
    'slug',         'dinner_same_day_cancel',
    'name',         'Cancelación mismo día',
    'description',  'Multa por cambiar a "no voy" el día del evento.',
    'isActive',     true,
    'trigger',      jsonb_build_object(
                      'eventType', 'rsvpChangedSameDay',
                      'config',    '{}'::jsonb
                    ),
    'conditions',   jsonb_build_array(
                      jsonb_build_object(
                        'type',   'alwaysTrue',
                        'config', '{}'::jsonb
                      )
                    ),
    'consequences', jsonb_build_array(
                      jsonb_build_object(
                        'type',   'fine',
                        'config', jsonb_build_object('amount', 200)
                      )
                    )
  ),
  -- Rule 4 — No-show
  jsonb_build_object(
    'slug',         'dinner_no_show',
    'name',         'No-show',
    'description',  'Multa por confirmar y no llegar (sin check-in).',
    'isActive',     true,
    'trigger',      jsonb_build_object(
                      'eventType', 'eventClosed',
                      'config',    '{}'::jsonb
                    ),
    'conditions',   jsonb_build_array(
                      jsonb_build_object(
                        'type',   'responseStatusIs',
                        'config', jsonb_build_object('status', 'going')
                      ),
                      jsonb_build_object(
                        'type',   'checkInExists',
                        'config', jsonb_build_object('exists', false)
                      )
                    ),
    'consequences', jsonb_build_array(
                      jsonb_build_object(
                        'type',   'fine',
                        'config', jsonb_build_object('amount', 300)
                      )
                    )
  ),
  -- Rule 5 — Anfitrión sin menú (default OFF)
  jsonb_build_object(
    'slug',         'dinner_host_no_menu',
    'name',         'Anfitrión sin menú',
    'description',  'Multa al host si no llenó la descripción 24h antes del evento.',
    'isActive',     false,
    'trigger',      jsonb_build_object(
                      'eventType', 'hoursBeforeEvent',
                      'config',    jsonb_build_object('hours', 24)
                    ),
    'conditions',   jsonb_build_array(
                      jsonb_build_object(
                        'type',   'eventDescriptionMissing',
                        'config', '{}'::jsonb
                      )
                    ),
    'consequences', jsonb_build_array(
                      jsonb_build_object(
                        'type',   'fine',
                        'config', jsonb_build_object('amount', 200)
                      )
                    )
  )
),
updated_at = now()
where id = 'basic_fines';
