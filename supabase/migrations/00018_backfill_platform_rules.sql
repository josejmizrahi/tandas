-- 00018 — Backfill platform-shape rules for pre-Sprint-1b groups
--
-- The original handoff noted: "5 default rules en grupos pre-Sprint-1b: solo
-- grupos creados después del 1b tienen las rules cargadas vía
-- seed_dinner_template_rules. Grupos viejos quedaron con Brand legacy rules
-- sin engine wiring."
--
-- This migration walks every group that has zero platform-shape rules and
-- inserts the 5 dinner_recurring template rules with the same payload as
-- seed_dinner_template_rules. Idempotent — skips groups that already have
-- any rule with consequences <> '[]'. Uses the group's first admin as
-- proposed_by; if there's no admin (orphaned group) it skips.
--
-- Legacy rows (consequences = '[]') are left untouched so the existing UI
-- doesn't break; the rule engine just ignores them since it filters on
-- consequences anyway.

do $$
declare
  g_row record;
  admin_id uuid;
begin
  for g_row in
    select g.id, g.name
    from public.groups g
    where not exists (
      select 1 from public.rules r
      where r.group_id = g.id
        and r.consequences <> '[]'::jsonb
    )
  loop
    -- First admin (oldest joined). Skip orphaned groups (no admin = abandoned).
    select user_id into admin_id
    from public.group_members
    where group_id = g_row.id and role = 'admin' and active
    order by joined_at asc
    limit 1;

    if admin_id is null then
      raise notice 'skipping group % (% — no active admin)', g_row.id, g_row.name;
      continue;
    end if;

    insert into public.rules (
      group_id, code, title, description, trigger, action,
      name, is_active, conditions, consequences,
      status, enabled, proposed_by
    )
    values
    (
      g_row.id,
      'dinner_late_arrival', 'Llegada tardía',
      'Multa escalonada por llegar después de la hora de la cena',
      jsonb_build_object('eventType','checkInRecorded','config','{}'::jsonb),
      jsonb_build_object('type','fine','amount_mxn',200),
      'Llegada tardía', true,
      jsonb_build_array(jsonb_build_object('type','checkInMinutesLate','config',jsonb_build_object('thresholdMinutes',0))),
      jsonb_build_array(jsonb_build_object('type','fine','config',jsonb_build_object('baseAmount',200,'stepAmount',50,'stepMinutes',30))),
      'active', true, admin_id
    ),
    (
      g_row.id,
      'dinner_no_response', 'No confirmó a tiempo',
      'Multa para quien no respondió RSVP antes del cierre',
      jsonb_build_object('eventType','eventClosed','config','{}'::jsonb),
      jsonb_build_object('type','fine','amount_mxn',200),
      'No confirmó a tiempo', true,
      jsonb_build_array(jsonb_build_object('type','responseStatusIs','config',jsonb_build_object('status','pending'))),
      jsonb_build_array(jsonb_build_object('type','fine','config',jsonb_build_object('amount',200))),
      'active', true, admin_id
    ),
    (
      g_row.id,
      'dinner_same_day_cancel', 'Cancelación mismo día',
      'Multa por cancelar la asistencia el mismo día del evento',
      jsonb_build_object('eventType','rsvpChangedSameDay','config','{}'::jsonb),
      jsonb_build_object('type','fine','amount_mxn',200),
      'Cancelación mismo día', true,
      jsonb_build_array(jsonb_build_object('type','alwaysTrue','config','{}'::jsonb)),
      jsonb_build_array(jsonb_build_object('type','fine','config',jsonb_build_object('amount',200))),
      'active', true, admin_id
    ),
    (
      g_row.id,
      'dinner_no_show', 'No-show',
      'Multa para quien confirmó asistencia pero no llegó',
      jsonb_build_object('eventType','eventClosed','config','{}'::jsonb),
      jsonb_build_object('type','fine','amount_mxn',300),
      'No-show', true,
      jsonb_build_array(jsonb_build_object('type','responseStatusIs','config',jsonb_build_object('status','going')),
                        jsonb_build_object('type','checkInExists','config',jsonb_build_object('exists',false))),
      jsonb_build_array(jsonb_build_object('type','fine','config',jsonb_build_object('amount',300))),
      'active', true, admin_id
    ),
    (
      g_row.id,
      'dinner_host_no_menu', 'Anfitrión sin menú',
      'Multa para el host si no llenó la descripción 24h antes',
      jsonb_build_object('eventType','hoursBeforeEvent','config',jsonb_build_object('hours',24)),
      jsonb_build_object('type','fine','amount_mxn',200),
      'Anfitrión sin menú', false,
      jsonb_build_array(jsonb_build_object('type','eventDescriptionMissing','config','{}'::jsonb)),
      jsonb_build_array(jsonb_build_object('type','fine','config',jsonb_build_object('amount',200))),
      'active', false, admin_id
    );

    raise notice 'backfilled platform rules for group % (%)', g_row.id, g_row.name;
  end loop;
end $$;
