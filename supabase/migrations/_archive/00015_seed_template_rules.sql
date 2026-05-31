-- 00015 — seed_dinner_template_rules RPC
--
-- Sprint 1b. Used by founder onboarding right after `create_group_with_admin`
-- to load the 5 default Platform rules atomically. Inserts both:
--   - new Platform columns: name, is_active, conditions, consequences
--   - legacy columns:       code, title, description, trigger, action, status, enabled
--
-- Until the legacy columns are dropped (posterior sprint), keeping both
-- written keeps the existing rule-listing UIs working unchanged.

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

  -- Idempotency: if any platform-shape rule already exists for this group
  -- (i.e. has consequences populated), skip. The founder onboarding may
  -- legitimately re-enter this step after a network blip; we don't want
  -- duplicates.
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
    false,  -- default OFF
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
