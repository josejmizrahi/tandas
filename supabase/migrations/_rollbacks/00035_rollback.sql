-- 00035 rollback — Remove slug column from rules + restore seed RPC.
--
-- Restores the 00015 version of `seed_dinner_template_rules` (no slug
-- column). Drops the `rules.slug` column and its index. Reverts the
-- defaultRules update on templates.recurring_dinner to the 00021 +
-- 00034 shape (no slug per rule).

-- =============================================================================
-- Restore templates.config.defaultRules (no slug)
-- =============================================================================

update public.templates
set config = jsonb_set(
  config,
  '{defaultRules}',
  jsonb_build_array(
    jsonb_build_object(
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

-- =============================================================================
-- Restore 00015 seed_dinner_template_rules
-- =============================================================================

create or replace function public.seed_dinner_template_rules(
  p_group_id uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;

  if exists (
    select 1 from public.rules
     where group_id = p_group_id
       and consequences <> '[]'::jsonb
  ) then
    return;
  end if;

  return query
  insert into public.rules (
    group_id, code, title, description, trigger, action,
    name, is_active, conditions, consequences,
    status, enabled, proposed_by
  )
  values
  (
    p_group_id,
    'dinner_late_arrival',
    'Llegada tardía',
    'Multa escalonada por llegar después de la hora de la cena',
    jsonb_build_object('eventType', 'checkInRecorded', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Llegada tardía',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'checkInMinutesLate', 'config', jsonb_build_object('thresholdMinutes', 0))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('baseAmount', 200, 'stepAmount', 50, 'stepMinutes', 30))
    ),
    'active', true, uid
  ),
  (
    p_group_id,
    'dinner_no_response',
    'No confirmó a tiempo',
    'Multa para quien no respondió RSVP antes del cierre',
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'No confirmó a tiempo',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'pending'))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', true, uid
  ),
  (
    p_group_id,
    'dinner_same_day_cancel',
    'Cancelación mismo día',
    'Multa por cancelar la asistencia el mismo día del evento',
    jsonb_build_object('eventType', 'rsvpChangedSameDay', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Cancelación mismo día',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'alwaysTrue', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', true, uid
  ),
  (
    p_group_id,
    'dinner_no_show',
    'No-show',
    'Multa para quien confirmó asistencia pero no llegó',
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 300),
    'No-show',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'going')),
      jsonb_build_object('type', 'checkInExists',     'config', jsonb_build_object('exists', false))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 300))
    ),
    'active', true, uid
  ),
  (
    p_group_id,
    'dinner_host_no_menu',
    'Anfitrión sin menú',
    'Multa para el host si no llenó la descripción 24h antes',
    jsonb_build_object('eventType', 'hoursBeforeEvent', 'config', jsonb_build_object('hours', 24)),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Anfitrión sin menú',
    false,
    jsonb_build_array(
      jsonb_build_object('type', 'eventDescriptionMissing', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', false, uid
  )
  returning *;
end;
$$;

revoke execute on function public.seed_dinner_template_rules(uuid) from public, anon;
grant  execute on function public.seed_dinner_template_rules(uuid) to authenticated;

-- =============================================================================
-- Drop slug column + index
-- =============================================================================

drop index if exists public.rules_slug_idx;

alter table public.rules
  drop column if exists slug;
