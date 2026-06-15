-- R.12.F.fix — update_calendar_event acepta p_metadata para que el iOS
-- pueda persistir los values del DynamicForm (event subtype fields).
-- Patrón conservador: merge con calendar_events.metadata existente
-- (preserva keys que iOS no conoce). p_metadata=NULL → no toca.
create or replace function public.update_calendar_event(
  p_event_id uuid,
  p_title text default null,
  p_description text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_location_text text default null,
  p_is_virtual boolean default null,
  p_recurrence_rule text default null,
  p_metadata jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_is_host boolean;
  v_can_manage boolean;
  v_new_title text;
  v_new_description text;
  v_new_starts_at timestamptz;
  v_new_ends_at timestamptz;
  v_new_location text;
  v_new_is_virtual boolean;
  v_new_recurrence text;
  v_new_metadata jsonb;
  v_diff_keys text[] := array[]::text[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id for update;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  v_is_host    := v_event.host_actor_id = v_caller;
  v_can_manage := public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage');
  if not (v_is_host or v_can_manage) then
    raise exception 'not authorized to edit event' using errcode = '42501';
  end if;

  if v_event.status not in ('scheduled', 'in_progress') then
    raise exception 'cannot edit event in terminal status %', v_event.status using errcode = '22023';
  end if;

  v_new_title       := coalesce(nullif(btrim(p_title), ''), v_event.title);
  v_new_description := coalesce(p_description, v_event.description);
  v_new_starts_at   := coalesce(p_starts_at, v_event.starts_at);
  v_new_ends_at     := coalesce(p_ends_at, v_event.ends_at);
  v_new_location    := coalesce(nullif(btrim(p_location_text), ''), v_event.location_text);
  v_new_is_virtual  := coalesce(p_is_virtual, v_event.is_virtual);
  v_new_recurrence  := coalesce(nullif(btrim(p_recurrence_rule), ''), v_event.recurrence_rule);
  -- R.12.F: merge en lugar de overwrite — preserva keys del backend que iOS no conoce.
  v_new_metadata    := case
    when p_metadata is null then v_event.metadata
    else coalesce(v_event.metadata, '{}'::jsonb) || p_metadata
  end;

  if v_new_ends_at is not null and v_new_ends_at < v_new_starts_at then
    raise exception 'ends_at must be on or after starts_at' using errcode = '22023';
  end if;

  if v_new_title       is distinct from v_event.title           then v_diff_keys := array_append(v_diff_keys, 'title'); end if;
  if v_new_description is distinct from v_event.description     then v_diff_keys := array_append(v_diff_keys, 'description'); end if;
  if v_new_starts_at   is distinct from v_event.starts_at       then v_diff_keys := array_append(v_diff_keys, 'starts_at'); end if;
  if v_new_ends_at     is distinct from v_event.ends_at         then v_diff_keys := array_append(v_diff_keys, 'ends_at'); end if;
  if v_new_location    is distinct from v_event.location_text   then v_diff_keys := array_append(v_diff_keys, 'location_text'); end if;
  if v_new_is_virtual  is distinct from v_event.is_virtual      then v_diff_keys := array_append(v_diff_keys, 'is_virtual'); end if;
  if v_new_recurrence  is distinct from v_event.recurrence_rule then v_diff_keys := array_append(v_diff_keys, 'recurrence_rule'); end if;
  if v_new_metadata    is distinct from v_event.metadata        then v_diff_keys := array_append(v_diff_keys, 'metadata'); end if;

  if array_length(v_diff_keys, 1) is null then
    return jsonb_build_object('event_id', p_event_id, 'event', to_jsonb(v_event), 'diff_keys', '[]'::jsonb, 'no_op', true);
  end if;

  update public.calendar_events
     set title           = v_new_title,
         description     = v_new_description,
         starts_at       = v_new_starts_at,
         ends_at         = v_new_ends_at,
         location_text   = v_new_location,
         is_virtual      = v_new_is_virtual,
         recurrence_rule = v_new_recurrence,
         metadata        = v_new_metadata
   where id = p_event_id;

  perform public._emit_activity(
    v_event.context_actor_id, v_caller,
    'event.updated', 'calendar_event', p_event_id,
    jsonb_build_object('diff_keys', to_jsonb(v_diff_keys))
  );

  return jsonb_build_object(
    'event_id', p_event_id,
    'event', (select to_jsonb(e) from public.calendar_events e where e.id = p_event_id),
    'diff_keys', to_jsonb(v_diff_keys),
    'no_op', false
  );
end; $$;

comment on function public.update_calendar_event(uuid, text, text, timestamptz, timestamptz, text, boolean, text, jsonb) is
  'R.12.F.fix: ahora acepta p_metadata jsonb (merge en lugar de overwrite). iOS lo usa para persistir DynamicForm values del event subtype.';
