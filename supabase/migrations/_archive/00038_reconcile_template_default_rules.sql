-- 00038 — Reconcile templates.config.defaultRules with the seed RPC.
--
-- Audit doc § 5.3 item 7b. Two parallel sources of "template default
-- rules" had drifted:
--
--   1. `templates.config.defaultRules` jsonb (seeded by 00021,
--      updated by 00035 to add slug). NOT read by iOS today
--      (TemplateRegistry is not yet wired into bootstrap), so this is
--      effectively documentation jsonb.
--
--   2. RPC `seed_dinner_template_rules` (00015 → 00035) actually
--      inserts rule rows into `public.rules` when a founder creates a
--      group with the recurring_dinner template. Load-bearing.
--
-- Drift items (table vs RPC):
--   - Rule 4 name: "No se presentó" / 500 MXN  vs  "No-show" / 300 MXN
--   - Rule 5 name: "Anfitrión sin descripción"
--                  / 100 MXN / active=true
--                  / conditions = [memberIsHost, eventDescriptionMissing]
--                vs "Anfitrión sin menú"
--                  / 200 MXN / active=false
--                  / conditions = [eventDescriptionMissing]
--
-- Plus: `ConditionType.memberIsHost` referenced in the table version
-- does NOT exist in the Swift enum or `_shared/ruleEngine.ts`. Pure
-- broken reference. Eliminated by this migration.
--
-- Decision (2026-05-07): the seed RPC wins. Aligning the table to
-- match the RPC is preferable to changing what's actually shipping
-- because:
--   a) Existing groups already have RPC-shape rules. No re-seed needed.
--   b) `DinnerRecurringTemplate.swift` and `MockRuleRepository` already
--      match the RPC, so iOS code is consistent post-fix.
--   c) When TemplateRegistry is eventually wired and the RPC starts
--      reading from this table (next phase of the templates-as-data
--      work), the table values will already be correct.
--
-- Effect: rewrite the recurring_dinner row's defaultRules array. Other
-- templates' configs unchanged. Slugs preserved from 00035.

update public.templates
set config = jsonb_set(
  config,
  '{defaultRules}',
  jsonb_build_array(
    jsonb_build_object(
      'slug',          'dinner_late_arrival',
      'name',          'Llegada tardía',
      'description',   'Multa escalada por minuto de retraso al check-in.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'checkInRecorded'),
      'conditions',    jsonb_build_array(
        jsonb_build_object(
          'type', 'checkInMinutesLate',
          'config', jsonb_build_object('thresholdMinutes', 0)
        )
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object(
            'baseAmount',  200,
            'stepAmount',  50,
            'stepMinutes', 30
          )
        )
      )
    ),
    jsonb_build_object(
      'slug',          'dinner_no_response',
      'name',          'No confirmó a tiempo',
      'description',   'Multa por no responder RSVP antes del cierre del evento.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'eventClosed'),
      'conditions',    jsonb_build_array(
        jsonb_build_object(
          'type', 'responseStatusIs',
          'config', jsonb_build_object('status', 'pending')
        )
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 200)
        )
      )
    ),
    jsonb_build_object(
      'slug',          'dinner_same_day_cancel',
      'name',          'Cancelación mismo día',
      'description',   'Multa por cambiar a "no voy" el día del evento.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'rsvpChangedSameDay'),
      'conditions',    jsonb_build_array(
        jsonb_build_object('type', 'alwaysTrue', 'config', jsonb_build_object())
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 200)
        )
      )
    ),
    -- Rule 4: aligned to RPC — name "No-show" (was "No se presentó"),
    -- amount 300 (was 500).
    jsonb_build_object(
      'slug',          'dinner_no_show',
      'name',          'No-show',
      'description',   'Multa por confirmar y no llegar (sin check-in).',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object('eventType', 'eventClosed'),
      'conditions',    jsonb_build_array(
        jsonb_build_object(
          'type', 'responseStatusIs',
          'config', jsonb_build_object('status', 'going')
        ),
        jsonb_build_object(
          'type', 'checkInExists',
          'config', jsonb_build_object('exists', false)
        )
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 300)
        )
      )
    ),
    -- Rule 5: aligned to RPC — name "Anfitrión sin menú" (was
    -- "Anfitrión sin descripción"), amount 200 (was 100), isActive
    -- false (was true), conditions = [eventDescriptionMissing] only
    -- (memberIsHost dropped — type doesn't exist in the rule engine).
    jsonb_build_object(
      'slug',          'dinner_host_no_menu',
      'name',          'Anfitrión sin menú',
      'description',   'Multa al host si no llenó la descripción 24h antes del evento.',
      'module',        'basic_fines',
      'isActive',      false,
      'trigger',       jsonb_build_object(
        'eventType', 'hoursBeforeEvent',
        'config',    jsonb_build_object('hours', 24)
      ),
      'conditions',    jsonb_build_array(
        jsonb_build_object('type', 'eventDescriptionMissing', 'config', jsonb_build_object())
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 200)
        )
      )
    )
  )
)
where id = 'recurring_dinner';

-- Note on next steps (deferred to follow-up, not this migration):
--   - Add a generic `seed_template_rules(p_template_id text, p_group_id uuid)`
--     RPC that reads from templates.config.defaultRules and inserts
--     into public.rules. Replaces template-specific RPCs (the dinner
--     one + future shared_resource one).
--   - Once the generic RPC ships, deprecate `seed_dinner_template_rules`.
--   - This makes templates.config.defaultRules truly canonical instead
--     of "documentation jsonb". Tracked alongside the
--     TemplateRegistry-wiring work in Plans/GroupTypeRemoval.md.
