-- 00062 rollback — Restore the dinner-specific seed RPC body and drop
-- the generic seed_template_rules. Restores the post-00058 state.

drop function if exists public.seed_dinner_template_rules(uuid);
drop function if exists public.seed_template_rules(text, uuid);

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
    group_id, slug, name, is_active, trigger, conditions, consequences,
    proposed_by
  )
  values
  (
    p_group_id, 'dinner_late_arrival',
    'Llegada tardía', true,
    jsonb_build_object('eventType', 'checkInRecorded', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'checkInMinutesLate', 'config', jsonb_build_object('thresholdMinutes', 0))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('baseAmount', 200, 'stepAmount', 50, 'stepMinutes', 30))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_no_response',
    'No confirmó a tiempo', true,
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'pending'))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_same_day_cancel',
    'Cancelación mismo día', true,
    jsonb_build_object('eventType', 'rsvpChangedSameDay', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'alwaysTrue', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_no_show',
    'No-show', true,
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'going')),
      jsonb_build_object('type', 'checkInExists',     'config', jsonb_build_object('exists', false))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 300))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_host_no_menu',
    'Anfitrión sin menú', false,
    jsonb_build_object('eventType', 'hoursBeforeEvent', 'config', jsonb_build_object('hours', 24)),
    jsonb_build_array(
      jsonb_build_object('type', 'eventDescriptionMissing', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    uid
  )
  returning *;
end;
$$;

revoke execute on function public.seed_dinner_template_rules(uuid) from public, anon;
grant  execute on function public.seed_dinner_template_rules(uuid) to authenticated;
