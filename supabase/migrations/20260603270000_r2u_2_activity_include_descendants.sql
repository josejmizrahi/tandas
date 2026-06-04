-- ============================================================================
-- R.2U.2 — list_activity con include_descendants
-- ============================================================================
-- Extiende list_activity con un 4° parámetro `p_include_descendants boolean`
-- (default false). Cuando true, la timeline incluye actividad de todos los
-- descendientes del contexto raíz a los que el caller tenga acceso (membership
-- activa). Esto preserva la doctrina R.2U: contains es organizacional, NO
-- transfiere rights ni membresía — sólo agrega la VISIBILIDAD que el caller
-- ya tenía por ser miembro de los descendientes.
--
-- Implementación: recursive CTE inline para descender + WHERE filter con
-- public.is_context_member para gatear por membership del caller. El cap de
-- 100 eventos se mantiene; orden occurred_at desc + created_at desc.
--
-- DROP previo de la firma 3-arg: CREATE OR REPLACE con signature distinta
-- crearía un overload, no un reemplazo (gotcha doctrina memorizada R.2T).
-- ============================================================================

drop function if exists public.list_activity(uuid, int, timestamptz);

create or replace function public.list_activity(
  p_context_actor_id uuid,
  p_limit int default 50,
  p_before timestamptz default null,
  p_include_descendants boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_limit int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  -- autoridad de lectura: miembro activo del contexto raíz
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  -- cap duro de 100
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);

  if not coalesce(p_include_descendants, false) then
    -- Path simple (preservado): sólo el contexto raíz
    return jsonb_build_object(
      'context_actor_id', p_context_actor_id,
      'include_descendants', false,
      'limit', v_limit,
      'activity', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ae.id,
          'event_type', ae.event_type,
          'actor_id', ae.actor_id,
          'context_actor_id', ae.context_actor_id,
          'subject_type', ae.subject_type,
          'subject_id', ae.subject_id,
          'payload', ae.payload,
          'resource_id', ae.resource_id,
          'decision_id', ae.decision_id,
          'obligation_id', ae.obligation_id,
          'occurred_at', ae.occurred_at) order by ae.occurred_at desc, ae.created_at desc)
        from (
          select * from public.activity_events
          where context_actor_id = p_context_actor_id
            and (p_before is null or occurred_at < p_before)
          order by occurred_at desc, created_at desc
          limit v_limit
        ) ae), '[]'::jsonb));
  end if;

  -- Path agregado: raíz + descendientes (filtrados por membership del caller)
  return jsonb_build_object(
    'context_actor_id', p_context_actor_id,
    'include_descendants', true,
    'limit', v_limit,
    'activity', coalesce((
      with recursive tree as (
        select p_context_actor_id::uuid as actor_id
        union
        select ar.object_actor_id
          from tree t
          join public.actor_relationships ar
            on ar.subject_actor_id = t.actor_id
           and ar.relationship_type = 'contains'
           and ar.object_actor_id is not null
           and (ar.ends_at is null or ar.ends_at > now())
      ),
      visible as (
        -- raíz siempre visible (ya gateamos arriba); descendientes filtrados
        -- por membership activa del caller — doctrina R.2U: membresía NO hereda
        select t.actor_id
          from tree t
         where t.actor_id = p_context_actor_id
            or public.is_context_member(t.actor_id)
      )
      select jsonb_agg(jsonb_build_object(
        'id', ae.id,
        'event_type', ae.event_type,
        'actor_id', ae.actor_id,
        'context_actor_id', ae.context_actor_id,
        'subject_type', ae.subject_type,
        'subject_id', ae.subject_id,
        'payload', ae.payload,
        'resource_id', ae.resource_id,
        'decision_id', ae.decision_id,
        'obligation_id', ae.obligation_id,
        'occurred_at', ae.occurred_at) order by ae.occurred_at desc, ae.created_at desc)
      from (
        select ae.* from public.activity_events ae
        join visible v on v.actor_id = ae.context_actor_id
        where (p_before is null or ae.occurred_at < p_before)
        order by ae.occurred_at desc, ae.created_at desc
        limit v_limit
      ) ae
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.list_activity(uuid, int, timestamptz, boolean) from public, anon;
grant execute on function public.list_activity(uuid, int, timestamptz, boolean) to authenticated, service_role;

comment on function public.list_activity(uuid, int, timestamptz, boolean) is
  'R.2U.2: lista activity del contexto. Si p_include_descendants=true, agrega timeline de descendientes (filtrados por membership del caller).';
