-- Mig 00253: delete_my_account wrapper + export_my_data sync
--
-- Contexto: ya existe infra ARCO completa (mig 00170 data_subject_rights,
-- mig 00174 data_rights_janitor):
--   - `request_data_deletion(p_scope)` — SYNC, pseudonimiza profile +
--     deactivates memberships + purge tokens. Logged en
--     data_subject_rights_requests + data_deletion_log.
--   - `request_data_export(p_kind)` — ASYNC, crea pending request que
--     debería procesarse por un cron... pero el executor no existe
--     todavía. iOS no puede simplemente llamarla y obtener data.
--
-- Esta migración:
--   1. `delete_my_account()` — wrapper Spanish-friendly que llama al
--      existente request_data_deletion + agrega los extras que faltan
--      (purge notification_preferences, set profiles.deleted_at flag
--      añadido en mig 00259, emit memberLeft system_event por grupo).
--      iOS llama esta y se desentiende del p_scope text[] underlying.
--   2. `export_my_data()` — SYNC executor: devuelve jsonb directo.
--      También loggea en data_subject_rights_requests como 'completed'
--      para audit trail compliance. Coexiste con request_data_export
--      async — V2 puede deprecar la async cuando export crezca lo
--      suficiente para necesitar offline processing.

-- =============================================================================
-- 1. delete_my_account — extiende request_data_deletion
-- =============================================================================

create or replace function public.delete_my_account()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_request_id uuid;
begin
  if v_user_id is null then
    raise exception 'authentication required'
      using errcode = 'insufficient_privilege';
  end if;

  -- 1. Delegar al RPC existente para la parte estándar (profile blank,
  --    tokens delete, memberships deactivate). Devuelve el request_id
  --    que loggea data_subject_rights_requests.
  v_request_id := public.request_data_deletion(
    ARRAY['profile', 'devices', 'group_membership']
  );

  -- 2. Spanish-friendly override del display_name (request_data_deletion
  --    pone "Removed user" en inglés). También set deleted_at flag para
  --    que la UI proyecte "Cuenta eliminada" sin tener que adivinar.
  update public.profiles set
    display_name = 'Cuenta eliminada',
    deleted_at   = now()
  where id = v_user_id;

  -- 3. Purga preferencias de notificación (PII personal, no audit value).
  --    El existente request_data_deletion no las tocaba.
  delete from public.notification_preferences
   where user_id = v_user_id;

  -- 4. Emit memberLeft system_event en cada grupo donde era miembro con
  --    reason=account_deleted. Sin esto el historial del grupo no
  --    refleja qué pasó — solo aparece "Jose" desactivado silenciosamente.
  insert into public.system_events (group_id, event_type, member_id, payload)
  select gm.group_id, 'memberLeft', gm.id,
         jsonb_build_object('reason', 'account_deleted')
    from public.group_members gm
   where gm.user_id = v_user_id and not gm.active and gm.id is not null;

  return v_request_id;
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  'LFPDPPP/CCPA right-to-erasure wrapper. Llama a request_data_deletion(full_scope) + override Spanish copy + set profiles.deleted_at + purge notification_preferences + emit memberLeft system_event por grupo. Devuelve request_id loggeado en data_subject_rights_requests. El cliente debe llamar signOut() después.';

-- =============================================================================
-- 2. export_my_data — SYNC version del data export
-- =============================================================================
--
-- Diferencia con request_data_export(p_kind): éste devuelve jsonb directo
-- en la llamada, no un request_id que hay que polling. Loggea el evento
-- en data_subject_rights_requests como 'completed' para audit ARCO.
--
-- Cobertura: profile + memberships + fines + rsvps + votes +
-- system_events (donde fui actor) + ledger_entries (de o hacia mí) +
-- notification_preferences. Scoped a auth.uid().

create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member_ids uuid[];
  v_request_id uuid;
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'authentication required'
      using errcode = 'insufficient_privilege';
  end if;

  -- Mis member_ids across grupos (incluye inactivos para export histórico).
  select coalesce(array_agg(id), '{}'::uuid[]) into v_member_ids
    from public.group_members
   where user_id = v_user_id;

  -- Construir el JSON agregado.
  with
    profile_data as (
      select to_jsonb(p.*) as p
      from public.profiles p where p.id = v_user_id
    ),
    memberships_data as (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', gm.id,
        'group_id', gm.group_id,
        'group_name', g.name,
        'role', gm.role,
        'on_committee', gm.on_committee,
        'turn_order', gm.turn_order,
        'active', gm.active,
        'joined_at', gm.joined_at,
        'display_name_override', gm.display_name_override
      ) order by gm.joined_at), '[]'::jsonb) as ms
      from public.group_members gm
      join public.groups g on g.id = gm.group_id
      where gm.user_id = v_user_id
    ),
    fines_data as (
      -- fines_view (mig 00150) tiene status/paid/waived derivados de
      -- ledger atoms; la tabla `fines` bare no las expone (mig 00151).
      select coalesce(jsonb_agg(to_jsonb(f.*) order by f.created_at), '[]'::jsonb) as fs
      from public.fines_view f where f.user_id = v_user_id
    ),
    rsvps_data as (
      select coalesce(jsonb_agg(to_jsonb(r.*) order by r.recorded_at), '[]'::jsonb) as rs
      from public.rsvp_actions r where r.member_id = any(v_member_ids)
    ),
    votes_data as (
      select coalesce(jsonb_agg(jsonb_build_object(
        'vote_id', vc.vote_id,
        'choice', vc.choice,
        'cast_at', vc.cast_at,
        'created_at', vc.created_at,
        'vote_title', v.title,
        'vote_type', v.vote_type
      ) order by vc.created_at), '[]'::jsonb) as vs
      from public.vote_casts vc
      left join public.votes v on v.id = vc.vote_id
      where vc.member_id = any(v_member_ids)
    ),
    events_data as (
      select coalesce(jsonb_agg(to_jsonb(se.*) order by se.occurred_at), '[]'::jsonb) as es
      from public.system_events se
      where se.member_id = any(v_member_ids)
    ),
    ledger_data as (
      select coalesce(jsonb_agg(to_jsonb(le.*) order by le.occurred_at), '[]'::jsonb) as ls
      from public.ledger_entries le
      where le.from_member_id = any(v_member_ids)
         or le.to_member_id = any(v_member_ids)
         or le.recorded_by = v_user_id
    ),
    prefs_data as (
      select coalesce(jsonb_agg(to_jsonb(np.*)), '[]'::jsonb) as ps
      from public.notification_preferences np where np.user_id = v_user_id
    )
  select jsonb_build_object(
    'exported_at', now(),
    'user_id', v_user_id,
    'schema_version', 1,
    'profile', (select p from profile_data),
    'memberships', (select ms from memberships_data),
    'fines', (select fs from fines_data),
    'rsvps', (select rs from rsvps_data),
    'votes', (select vs from votes_data),
    'system_events', (select es from events_data),
    'ledger_entries', (select ls from ledger_data),
    'notification_preferences', (select ps from prefs_data)
  ) into v_result;

  -- Loggear el export en data_subject_rights_requests para audit ARCO.
  -- portability = derecho a llevarse la data (LFPDPPP art. 22 acceso +
  -- CCPA right-to-know). status=completed porque ya está hecho.
  insert into public.data_subject_rights_requests (
    user_id, kind, status, payload, executed_at, result
  ) values (
    v_user_id,
    'portability'::data_right_kind,
    'completed'::data_right_status,
    jsonb_build_object('requested_via', 'export_my_data', 'sync', true),
    now(),
    jsonb_build_object('records_exported', jsonb_build_object(
      'memberships', jsonb_array_length(v_result->'memberships'),
      'fines',       jsonb_array_length(v_result->'fines'),
      'rsvps',       jsonb_array_length(v_result->'rsvps'),
      'votes',       jsonb_array_length(v_result->'votes'),
      'events',      jsonb_array_length(v_result->'system_events'),
      'ledger',      jsonb_array_length(v_result->'ledger_entries')
    ))
  ) returning id into v_request_id;

  -- Embed el request_id en la respuesta para que iOS pueda referenciarlo
  -- si el usuario pregunta por audit trail.
  return v_result || jsonb_build_object('audit_request_id', v_request_id);
end;
$$;

revoke execute on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;

comment on function public.export_my_data() is
  'LFPDPPP art. 22 / CCPA right-to-know. SYNC version — devuelve jsonb directo + loggea en data_subject_rights_requests como portability completed. Coexiste con request_data_export async. Cobertura: profile, memberships, fines, rsvps, votes, system_events (donde fui actor), ledger_entries, notification_preferences. schema_version=1.';
