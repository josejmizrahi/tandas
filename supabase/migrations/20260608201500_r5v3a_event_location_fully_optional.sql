-- R.5V.3A.event.fix (2026-06-08) — Founder doctrina extendida:
-- location es OPCIONAL siempre. Muchos eventos no tienen ubicación al momento
-- de crearse (host rota, lugar TBD, evento informal). Drop F.EVENT.5 check.
--
-- Reemplaza ambos write-paths (create + update) eliminando el RAISE
-- 'location_required'. El resto de la lógica idéntico al estado anterior.
--
-- Esta mig supersede a 20260608200000_r5v3a_event_location_optional_when_weekly
-- (que sólo había relajado el check para recurring weekly). Founder pidió
-- relajación total porque "hay muchos eventos que no rota el host".

CREATE OR REPLACE FUNCTION public.create_calendar_event(
  p_context_actor_id uuid,
  p_title text,
  p_event_type text,
  p_starts_at timestamp with time zone,
  p_ends_at timestamp with time zone DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_timezone text DEFAULT 'America/Mexico_City',
  p_location_text text DEFAULT NULL,
  p_recurrence_rule text DEFAULT NULL,
  p_host_actor_id uuid DEFAULT NULL,
  p_invite_all_members boolean DEFAULT true,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_client_id text DEFAULT NULL,
  p_is_virtual boolean DEFAULT false,
  p_recurrence_count integer DEFAULT NULL,
  p_recurrence_until timestamp with time zone DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
  v_location text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'events.create') then
    raise exception 'not authorized to create events in context %', p_context_actor_id using errcode = '42501';
  end if;

  v_location := nullif(btrim(coalesce(p_location_text, '')), '');

  -- R.5V.3A.event.fix: location es opcional siempre. Sin check de
  -- location_required. Si el founder/host la define después via edit,
  -- queda registrada. Si nunca se define, el evento simplemente no tiene
  -- ubicación física asociada (caso natural para muchos eventos informales
  -- o de host rotativo).

  if (p_recurrence_count is not null or p_recurrence_until is not null)
     and p_recurrence_rule is null then
    raise exception 'recurrence bounds require recurrence_rule' using errcode = '22023';
  end if;
  if p_recurrence_count is not null and p_recurrence_count <= 0 then
    raise exception 'recurrence_count must be positive' using errcode = '22023';
  end if;
  if p_recurrence_until is not null and p_recurrence_until <= p_starts_at then
    raise exception 'recurrence_until must be after starts_at' using errcode = '22023';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.calendar_events
     where context_actor_id = p_context_actor_id and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('event_id', v_existing,
        'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_existing));
    end if;
  end if;

  insert into public.calendar_events
    (context_actor_id, title, description, event_type, starts_at, ends_at, timezone,
     location_text, recurrence_rule, host_actor_id, metadata, client_id, created_by_actor_id,
     is_virtual, recurrence_count, recurrence_until, occurrence_number)
  values
    (p_context_actor_id, btrim(p_title), p_description, p_event_type, p_starts_at, p_ends_at, p_timezone,
     v_location, p_recurrence_rule, coalesce(p_host_actor_id, v_caller),
     coalesce(p_metadata, '{}'::jsonb), p_client_id, v_caller,
     p_is_virtual, p_recurrence_count, p_recurrence_until, 1)
  returning id into v_id;

  update public.calendar_events set series_id = v_id where id = v_id and series_id is null;

  if p_invite_all_members and p_context_actor_id <> v_caller then
    insert into public.event_participants (event_id, participant_actor_id, status)
    select v_id, am.member_actor_id, 'invited'
      from public.actor_memberships am
     where am.context_actor_id = p_context_actor_id and am.membership_status = 'active'
    on conflict (event_id, participant_actor_id) do nothing;
  else
    insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    values (v_id, v_caller, 'going', now())
    on conflict (event_id, participant_actor_id) do nothing;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'event.created', 'calendar_event', v_id,
    jsonb_build_object('title', btrim(p_title), 'event_type', p_event_type, 'starts_at', p_starts_at,
                       'is_virtual', p_is_virtual,
                       'recurrence_count', p_recurrence_count,
                       'recurrence_until', p_recurrence_until));

  return jsonb_build_object('event_id', v_id,
    'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_id),
    'participants', (select count(*) from public.event_participants where event_id = v_id));
end; $function$;


CREATE OR REPLACE FUNCTION public.update_calendar_event(
  p_event_id uuid,
  p_title text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_starts_at timestamp with time zone DEFAULT NULL,
  p_ends_at timestamp with time zone DEFAULT NULL,
  p_location_text text DEFAULT NULL,
  p_is_virtual boolean DEFAULT NULL,
  p_recurrence_rule text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
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

  -- R.5V.3A.event.fix: location es opcional siempre. Sin check de
  -- location_required (founder doctrina extendida 2026-06-08).

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

  if array_length(v_diff_keys, 1) is null then
    return jsonb_build_object(
      'event_id', p_event_id,
      'event', to_jsonb(v_event),
      'diff_keys', '[]'::jsonb,
      'no_op', true
    );
  end if;

  update public.calendar_events
     set title           = v_new_title,
         description     = v_new_description,
         starts_at       = v_new_starts_at,
         ends_at         = v_new_ends_at,
         location_text   = v_new_location,
         is_virtual      = v_new_is_virtual,
         recurrence_rule = v_new_recurrence
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
end; $function$;
