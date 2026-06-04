-- R.2T — Reservation ≠ Event (doctrina)
-- Agrega `source_event_id` opcional en resource_reservations (link Reservation → Event).
-- Extiende request_resource_reservation con p_source_event_id (nullable, default NULL).
-- NO modifica el resto del flujo: detect_reservation_conflicts sigue overlap-based.
-- Capacity/seats es R.2T-CAPACITY (out of scope).

-- 1. Columna nullable + index parcial.
alter table public.resource_reservations
  add column if not exists source_event_id uuid null
    references public.calendar_events(id) on delete set null;

create index if not exists ix_resource_reservations_source_event
  on public.resource_reservations(source_event_id)
  where source_event_id is not null;

-- 2. Rebuild request_resource_reservation con p_source_event_id al final.
--    Mantiene el resto del cuerpo idéntico (R.2F priority + R.2M reservable +
--    rights gating + idempotencia por client_id).
--    El nuevo parámetro NO afecta lógica de conflictos.
--
--    DROP de la firma vieja: CREATE OR REPLACE con firma distinta produciría
--    un overload en vez de reemplazar, y PostgREST no resolvería sin ambigüedad.
drop function if exists public.request_resource_reservation(
  uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text
);

create or replace function public.request_resource_reservation(
  p_resource_id uuid,
  p_context_actor_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reserved_for_actor_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null,
  p_source_event_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid;
  v_id uuid;
  v_existing uuid;
  v_conflicts integer;
  v_recent_use integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_target := coalesce(p_reserved_for_actor_id, v_caller);

  if not exists (select 1 from public.resources where id = p_resource_id and archived_at is null) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  -- R.2M: sólo los tipos con capability 'reservable' pueden reservarse.
  if not public.resource_can(p_resource_id, 'reservable') then
    raise exception 'resource type does not support reservations' using errcode = '22023';
  end if;

  -- R.2T: si se pasa source_event_id, validar que el evento existe y está vivo
  -- en el mismo contexto que la reservación. No obliga a tenerlo.
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

  -- R.2F: rights gating.
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

  -- Idempotencia por client_id.
  if p_client_id is not null then
    select id into v_existing from public.resource_reservations
     where requested_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('reservation_id', v_existing,
        'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_existing));
    end if;
  end if;

  -- R.2F priority: least_recent_use_wins.
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
$$;

-- GRANT EXECUTE: REVOKE FROM anon + GRANT TO authenticated/service_role.
-- Sin esto, producción da 42501 (ver feedback_grant_execute_authenticated_mandatory).
revoke all on function public.request_resource_reservation(
  uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text, uuid
) from public, anon;
grant execute on function public.request_resource_reservation(
  uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text, uuid
) to authenticated, service_role;
