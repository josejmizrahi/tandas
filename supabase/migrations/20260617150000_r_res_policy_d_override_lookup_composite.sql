-- R.RES.POLICY.D — override lookup composit en request_resource_reservation
--
-- Founder Flow #5 rationale: cada recurso puede tener override de la policy
-- default del subtype. Casa Valle hereda 'day' del subtype primary_residence,
-- pero el owner puede setear min=2 días o advance=90.
--
-- Schema decision: usar `resources.metadata.reservation_policy_override`
-- (jsonb existente) sin nueva tabla. Si presente, sobreescribe el default
-- del subtype. Si NO, fallback al subtype del catalog (R.RES.POLICY.A).
--
-- Cambio: el lookup `v_policy` ahora prefiere override > subtype default.
-- Resto idéntico al body de E (enforcement intacto).

create or replace function public.request_resource_reservation(
  p_resource_id uuid,
  p_context_actor_id uuid,
  p_starts_at timestamp with time zone,
  p_ends_at timestamp with time zone,
  p_reserved_for_actor_id uuid default null,
  p_metadata jsonb default '{}',
  p_client_id text default null,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid;
  v_id uuid;
  v_existing uuid;
  v_conflicts integer;
  v_recent_use integer;
  v_subtype_key text;
  v_resource_metadata jsonb;
  v_policy jsonb;
  v_granularity text;
  v_min_units integer;
  v_max_units integer;
  v_advance_days integer;
  v_unit_seconds numeric;
  v_duration_units numeric;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_target := coalesce(p_reserved_for_actor_id, v_caller);

  if not exists (select 1 from public.resources where id = p_resource_id and archived_at is null) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  if not public.resource_can(p_resource_id, 'reservable') then
    raise exception 'resource type does not support reservations' using errcode = '22023';
  end if;

  select r.resource_subtype_key, r.metadata
    into v_subtype_key, v_resource_metadata
    from public.resources r
   where r.id = p_resource_id;

  -- R.RES.POLICY.D — override lookup composit.
  v_policy := v_resource_metadata->'reservation_policy_override';

  if v_policy is null and v_subtype_key is not null then
    select rs.metadata->'reservation_policy' into v_policy
      from public.resource_subtypes rs
     where rs.subtype_key = v_subtype_key;
  end if;

  if v_policy is not null then
    v_granularity := v_policy->>'granularity';
    v_min_units := nullif(v_policy->>'min_duration_units', 'null')::integer;
    v_max_units := nullif(v_policy->>'max_duration_units', 'null')::integer;
    v_advance_days := nullif(v_policy->>'advance_window_days', 'null')::integer;

    if v_granularity = 'none' then
      raise exception 'resource subtype % is not reservable (granularity=none)', v_subtype_key
        using errcode = '22023';
    end if;

    v_unit_seconds := case v_granularity
      when 'day'  then 86400
      when 'hour' then 3600
      else 0
    end;

    if v_unit_seconds > 0 then
      v_duration_units := extract(epoch from (p_ends_at - p_starts_at)) / v_unit_seconds;

      if v_min_units is not null and v_duration_units < v_min_units then
        raise exception 'duration_below_minimum: %ud requested, min %u', v_duration_units, v_min_units
          using errcode = '22023';
      end if;

      if v_max_units is not null and v_duration_units > v_max_units then
        raise exception 'duration_above_maximum: %ud requested, max %u', v_duration_units, v_max_units
          using errcode = '22023';
      end if;
    end if;

    if v_advance_days is not null
       and p_starts_at > now() + make_interval(days => v_advance_days) then
      raise exception 'advance_window_exceeded: starts_at exceeds % days from now', v_advance_days
        using errcode = '22023';
    end if;
  end if;

  if p_source_event_id is not null then
    if not exists (
      select 1 from public.calendar_events
      where id = p_source_event_id
        and cancelled_at is null
        and context_actor_id = p_context_actor_id
    ) then
      raise exception 'source event not found in context %', p_context_actor_id
        using errcode = 'P0002';
    end if;
  end if;

  if not (
    public.actor_has_right(v_caller, p_resource_id, 'USE')
    or public.actor_has_right(v_caller, p_resource_id, 'MANAGE')
    or public.actor_has_right(v_caller, p_resource_id, 'OWN')
    or exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = p_resource_id
        and rr.right_kind in ('USE', 'MANAGE', 'OWN', 'GOVERN')
        and rr.revoked_at is null and rr.expired_at is null
        and (rr.starts_at is null or rr.starts_at <= now())
        and (rr.ends_at is null or rr.ends_at > now())
        and public.has_actor_authority(rr.holder_actor_id, v_caller, 'resources.manage'))
  ) then
    raise exception 'reserving requires USE, MANAGE or OWN right on resource %', p_resource_id
      using errcode = '42501';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.resource_reservations
     where requested_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('reservation_id', v_existing,
        'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_existing));
    end if;
  end if;

  select count(*) into v_recent_use from public.resource_reservations rr
   where rr.resource_id = p_resource_id
     and rr.reserved_for_actor_id = v_target
     and rr.status in ('confirmed', 'completed')
     and rr.starts_at > now() - interval '90 days';

  insert into public.resource_reservations
    (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id,
     starts_at, ends_at, metadata, client_id, priority_score, source_event_id)
  values
    (p_resource_id, p_context_actor_id, v_caller, v_target,
     p_starts_at, p_ends_at,
     coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
       'priority_rule', 'least_recent_use_wins', 'recent_use_count', v_recent_use),
     p_client_id, v_recent_use, p_source_event_id)
  returning id into v_id;

  select count(*) into v_conflicts from public.detect_reservation_conflicts(p_resource_id);

  perform public._emit_activity(p_context_actor_id, v_caller, 'reservation.requested', 'reservation', v_id,
    jsonb_build_object(
      'resource_id', p_resource_id,
      'starts_at', p_starts_at,
      'ends_at', p_ends_at,
      'conflicts_detected', v_conflicts,
      'priority_score', v_recent_use,
      'source_event_id', p_source_event_id),
    p_resource_id := p_resource_id);

  return jsonb_build_object('reservation_id', v_id, 'conflicts_detected', v_conflicts,
    'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_id));
end;
$function$;

revoke execute on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text, uuid) from public, anon;
grant execute on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text, uuid) to authenticated;
