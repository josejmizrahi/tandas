-- Mig 00253: delete_my_account + export_my_data RPCs
--
-- Cierra el gap de compliance LFPDPPP/CCPA marcado como pending en
-- Vision.md §"Checklist inmediato" item #7-equivalent (privacy ARCO).
-- Sin estas RPCs, un usuario que quiere ejercer su derecho de
-- supresión/portabilidad no tiene cómo desde la app.
--
-- Ambas son SECURITY DEFINER porque cruzan tablas con RLS por user_id;
-- el guard inicial es `auth.uid()` para asegurar que un usuario solo
-- puede operar sobre su propia data.

-- =============================================================================
-- 1. delete_my_account — pseudonymize PII, preserve atoms
-- =============================================================================
--
-- Estrategia (alineada con Vision.md §"Migración, UX y flujos" sobre
-- privacy + append-only):
--
--   PSEUDONIMIZAR identidad personal:
--     - profiles: blank display_name, avatar_url, phone; locale/tz
--       resetean al default; deleted_at = now()
--     - notification_tokens: DELETE (push tokens son PII vivos sin
--       valor de retención auditable)
--     - notification_preferences: DELETE (preferencias personales)
--
--   PRESERVAR átomos (audit trail):
--     - group_members: active=false + joined_at intacto; FKs preservan
--       referencia simbólica en system_events/vote_casts/rsvp_actions/
--       ledger_entries
--     - fines: no se tocan; user_id sigue apuntando a auth.users id
--     - system_events/vote_casts/rsvp_actions/ledger_entries: no se
--       tocan; ya son append-only por guards (migs 00103/00162/00163/
--       00166)
--
--   NO TOCAR auth.users:
--     - Para evitar cascade-delete que rompería los FKs append-only
--       (fines.user_id ON DELETE CASCADE, etc.). El usuario puede
--       técnicamente volver a iniciar sesión pero su profile estará
--       pseudonimizado y sin grupos activos — efectivamente account
--       muerta desde la perspectiva del producto.
--     - Si el operador necesita bannear el auth.user, lo hace fuera
--       de banda (Supabase Studio o edge function con service_role).

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated'
      using errcode = 'P0001';
  end if;

  -- 1. Pseudonimizar profile. Idempotente: si ya está eliminado,
  --    refresca timestamp pero no rompe.
  update public.profiles set
    display_name = 'Cuenta eliminada',
    avatar_url   = null,
    phone        = null,
    locale       = 'es-MX',
    timezone     = 'America/Mexico_City',
    deleted_at   = now(),
    updated_at   = now()
  where id = v_user_id;

  -- 2. Deactivate group memberships. Atoms con member_id apuntando
  --    a estos rows siguen siendo legibles; las vistas proyectarán
  --    "Cuenta eliminada" como actor name via profiles join.
  update public.group_members set
    active = false
  where user_id = v_user_id and active = true;

  -- 3. PURGE push tokens (PII viva, no audit value).
  delete from public.notification_tokens
   where user_id = v_user_id;

  -- 4. PURGE notification preferences (personal config).
  delete from public.notification_preferences
   where user_id = v_user_id;

  -- 5. Append a system_event en cada grupo donde era miembro para
  --    que el historial muestre el evento de eliminación.
  insert into public.system_events (group_id, event_type, member_id, payload)
  select gm.group_id, 'memberLeft', gm.id,
         jsonb_build_object('reason', 'account_deleted')
    from public.group_members gm
   where gm.user_id = v_user_id;
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  'LFPDPPP/CCPA right-to-erasure. Pseudonimiza profile, desactiva memberships, purga push tokens + notification preferences. NO toca atoms (system_events, vote_casts, rsvp_actions, ledger_entries, fines) ni auth.users — son append-only por design. El cliente debe llamar signOut() después.';

-- =============================================================================
-- 2. export_my_data — right to data portability
-- =============================================================================
--
-- Devuelve jsonb con todo lo que el usuario actual puede reclamar como
-- "su data". Compatible con LFPDPPP art. 22 (acceso) y CCPA §1798.110
-- (right to know). Formato: un solo JSON document, fácil de descargar/
-- compartir desde iOS.
--
-- Cobertura:
--   - profile (identidad)
--   - memberships (group_members + group name + role)
--   - fines (issued contra mí)
--   - rsvps (mis respuestas a eventos, vía member_id)
--   - vote_casts (mis votos emitidos, vía member_id)
--   - system_events donde yo fui actor (member_id en mis memberships)
--   - ledger_entries donde yo soy from o to member
--   - notification_preferences

create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member_ids uuid[];
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Not authenticated'
      using errcode = 'P0001';
  end if;

  -- Mis member_ids across grupos. Incluye inactivos para que el export
  -- sea histórico completo, no solo "lo que tengo ahora".
  select array_agg(id) into v_member_ids
    from public.group_members
   where user_id = v_user_id;
  v_member_ids := coalesce(v_member_ids, '{}'::uuid[]);

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
      select coalesce(jsonb_agg(to_jsonb(f.*) order by f.created_at), '[]'::jsonb) as fs
      from public.fines f where f.user_id = v_user_id
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

  return v_result;
end;
$$;

revoke execute on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;

comment on function public.export_my_data() is
  'LFPDPPP/CCPA right-to-know / data portability. Devuelve jsonb con profile + memberships + fines + rsvps + votes + system_events + ledger_entries + notification_preferences del usuario actual. schema_version=1 — bump cuando cambie shape.';
