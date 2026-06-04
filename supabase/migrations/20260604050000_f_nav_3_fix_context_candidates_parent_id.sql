-- F.NAV.3 fix: context_candidates expone parent_context_actor_id desde
-- actor_relationships ('contains', activo). Permite a ContextsListView
-- mostrar sólo contextos raíz; los hijos viven dentro del parent.

create or replace function public.context_candidates()
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  return jsonb_build_object(
    'personal_context', (select to_jsonb(a) from public.actors a where a.id = v_caller),
    'contexts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'context_actor_id', a.id,
        'display_name', a.display_name,
        'actor_kind', a.actor_kind,
        'actor_subtype', a.actor_subtype,
        'visibility', a.visibility,
        'membership_type', am.membership_type,
        'member_count', (select count(*) from public.actor_memberships x
                         where x.context_actor_id = a.id and x.membership_status = 'active'),
        'roles', coalesce((
          select jsonb_agg(r.role_key)
            from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where ra.context_actor_id = a.id and ra.member_actor_id = v_caller), '[]'::jsonb),
        -- F.NAV.3 — parent_context_actor_id desde actor_relationships('contains', activo).
        -- Si el contexto es hijo de otro, devolvemos el id del parent; null para raíces.
        'parent_context_actor_id', (
          select rel.subject_actor_id
          from public.actor_relationships rel
          where rel.object_actor_id = a.id
            and rel.relationship_type = 'contains'
            and (rel.starts_at is null or rel.starts_at <= now())
            and (rel.ends_at is null or rel.ends_at > now())
          limit 1
        )
      ) order by a.created_at)
      from public.actor_memberships am
      join public.actors a on a.id = am.context_actor_id
      where am.member_actor_id = v_caller and am.membership_status = 'active'
        and a.archived_at is null
    ), '[]'::jsonb)
  );
end; $$;

comment on function public.context_candidates() is
  'F.NAV.3: contextos del caller. Incluye parent_context_actor_id (null para raíces) para que iOS filtre la lista plana.';
