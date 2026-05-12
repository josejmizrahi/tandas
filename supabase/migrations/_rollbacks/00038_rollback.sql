-- 00038 rollback — Restore the pre-reconciliation defaultRules shape.
--
-- Reverts to the values written by 00035 (which mirror 00021 with slugs
-- added). Re-introduces the drift: rule 4 = "No se presentó" / 500,
-- rule 5 = "Anfitrión sin descripción" / 100 / active=true with
-- memberIsHost condition.
--
-- Use only if 00038 caused a regression that needs immediate revert.
-- Note that the seed RPC is unaffected by either migration — rolling
-- back this jsonb only diverges the docs from prod behavior again.

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
    jsonb_build_object(
      'slug',          'dinner_no_show',
      'name',          'No se presentó',
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
          'config', jsonb_build_object('amount', 500)
        )
      )
    ),
    jsonb_build_object(
      'slug',          'dinner_host_no_menu',
      'name',          'Anfitrión sin descripción',
      'description',   'Multa al host si no propuso menú/lugar 24h antes.',
      'module',        'basic_fines',
      'isActive',      true,
      'trigger',       jsonb_build_object(
        'eventType', 'hoursBeforeEvent',
        'config',    jsonb_build_object('hours', 24)
      ),
      'conditions',    jsonb_build_array(
        jsonb_build_object('type', 'memberIsHost', 'config', jsonb_build_object()),
        jsonb_build_object('type', 'eventDescriptionMissing', 'config', jsonb_build_object())
      ),
      'consequences',  jsonb_build_array(
        jsonb_build_object(
          'type', 'fine',
          'config', jsonb_build_object('amount', 100)
        )
      )
    )
  )
)
where id = 'recurring_dinner';
