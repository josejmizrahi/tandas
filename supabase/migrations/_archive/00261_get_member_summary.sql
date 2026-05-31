-- Mig 00254: get_member_summary(p_group_id, p_user_id)
--
-- Backend para MemberDetailView en iOS. Antes el detail era solo
-- avatar + nombre + roles + fecha de unión; ahora podemos mostrar
-- stats reales: % asistencia, multas pendientes/pagadas, votos
-- emitidos, eventos asistidos.
--
-- Una RPC en lugar de fan-out cliente reduce 5 queries a 1, y
-- centraliza el permission check (caller debe ser miembro del
-- grupo o no se devuelve nada).
--
-- Cobertura por scope (group_id):
--   - rsvps_total: count de rsvp_actions para resources del grupo
--   - rsvps_going: count con latest status = 'going'
--   - events_attended: count de check_ins (proxy de asistencia real)
--   - events_eligible: count de resources type=event ya cerrados (denom para %)
--   - fines_pending_count / fines_pending_amount_cents:
--       officialized + not paid + not waived
--   - fines_paid_count / fines_paid_amount_cents
--   - votes_cast: count en vote_casts donde member_id pertenece al usuario
--   - joined_at, role, active

create or replace function public.get_member_summary(
  p_group_id uuid,
  p_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_caller uuid := auth.uid();
  v_member record;
  v_rsvps_total int := 0;
  v_rsvps_going int := 0;
  v_events_attended int := 0;
  v_events_eligible int := 0;
  v_fines_pending_count int := 0;
  v_fines_pending_amount_cents bigint := 0;
  v_fines_paid_count int := 0;
  v_fines_paid_amount_cents bigint := 0;
  v_votes_cast int := 0;
begin
  if v_caller is null then
    raise exception 'authentication required'
      using errcode = 'insufficient_privilege';
  end if;

  -- Permission gate: caller must be member of this group (active or
  -- inactive — admins viewing past members still need access). Sin
  -- esto cualquier auth.uid() podría consultar stats de cualquier
  -- (group, user) tuple.
  if not exists (
    select 1 from public.group_members
     where group_id = p_group_id and user_id = v_caller
  ) then
    raise exception 'not a member of this group'
      using errcode = 'insufficient_privilege';
  end if;

  -- Subject member row. Necesario para el join con atoms
  -- (rsvp_actions, vote_casts) que usan member_id, no user_id.
  select id, role, active, joined_at, on_committee
    into v_member
    from public.group_members
   where group_id = p_group_id and user_id = p_user_id
   limit 1;

  if not found then
    -- El subject no es (ni fue) miembro de este grupo. Devolvemos
    -- shape vacío en lugar de error para que la UI pueda mostrar
    -- "Sin actividad" sin manejar excepción.
    return jsonb_build_object(
      'group_id', p_group_id,
      'user_id', p_user_id,
      'is_member', false,
      'rsvps_total', 0,
      'rsvps_going', 0,
      'events_attended', 0,
      'events_eligible', 0,
      'attendance_rate', null,
      'fines_pending_count', 0,
      'fines_pending_amount_cents', 0,
      'fines_paid_count', 0,
      'fines_paid_amount_cents', 0,
      'votes_cast', 0,
      'joined_at', null,
      'role', null,
      'active', false
    );
  end if;

  -- RSVPs: latest-per-(resource,member) projection. Usamos
  -- attendance_view que ya hace ese reduce.
  select
    count(*) filter (where rsvp_status is not null),
    count(*) filter (where rsvp_status = 'going')
    into v_rsvps_total, v_rsvps_going
    from public.attendance_view
   where group_id = p_group_id and member_id = v_member.id;

  -- Events attended: check_in registrado (proxy de asistencia real).
  select count(*)
    into v_events_attended
    from public.attendance_view
   where group_id = p_group_id
     and member_id = v_member.id
     and arrived_at is not null;

  -- Events eligible: resources type=event ya cerrados que el member
  -- pudo haber asistido. Excluye los pre-membership por joined_at.
  select count(*)
    into v_events_eligible
    from public.resources r
   where r.group_id = p_group_id
     and r.resource_type = 'event'
     and r.status in ('closed', 'cancelled')
     and (r.metadata->>'starts_at')::timestamptz >= v_member.joined_at;

  -- Fines en este grupo, segregadas por status. fines_view (mig 00150)
  -- es la projection con status/paid/waived derivados de ledger atoms;
  -- la tabla `fines` bare no tiene esas columnas (mig 00151 las dropeó).
  select
    count(*) filter (where status = 'officialized' and not paid and not waived),
    coalesce(sum(amount * 100) filter (where status = 'officialized' and not paid and not waived), 0),
    count(*) filter (where paid),
    coalesce(sum(amount * 100) filter (where paid), 0)
    into v_fines_pending_count, v_fines_pending_amount_cents,
         v_fines_paid_count, v_fines_paid_amount_cents
    from public.fines_view
   where group_id = p_group_id and user_id = p_user_id;

  -- Votos emitidos en este grupo (vote_casts pertenecen a member_id;
  -- el v_member.id puede haber cambiado si el usuario salió y volvió.
  -- Cubrimos todas las membresías históricas del user en el grupo).
  with my_member_ids as (
    select id from public.group_members
     where group_id = p_group_id and user_id = p_user_id
  )
  select count(*)
    into v_votes_cast
    from public.vote_casts vc
    join public.votes v on v.id = vc.vote_id
   where v.group_id = p_group_id
     and vc.member_id in (select id from my_member_ids)
     and vc.choice <> 'pending';

  return jsonb_build_object(
    'group_id', p_group_id,
    'user_id', p_user_id,
    'is_member', true,
    'rsvps_total', v_rsvps_total,
    'rsvps_going', v_rsvps_going,
    'events_attended', v_events_attended,
    'events_eligible', v_events_eligible,
    'attendance_rate', case
      when v_events_eligible > 0 then round(v_events_attended::numeric / v_events_eligible::numeric, 2)
      else null
    end,
    'fines_pending_count', v_fines_pending_count,
    'fines_pending_amount_cents', v_fines_pending_amount_cents,
    'fines_paid_count', v_fines_paid_count,
    'fines_paid_amount_cents', v_fines_paid_amount_cents,
    'votes_cast', v_votes_cast,
    'joined_at', v_member.joined_at,
    'role', v_member.role,
    'active', v_member.active,
    'on_committee', v_member.on_committee
  );
end;
$$;

revoke execute on function public.get_member_summary(uuid, uuid) from public, anon;
grant execute on function public.get_member_summary(uuid, uuid) to authenticated;

comment on function public.get_member_summary(uuid, uuid) is
  'Stats agregadas de un miembro en un grupo específico: asistencia, multas, votos. Caller debe ser miembro del grupo. Backend para MemberDetailView.';
