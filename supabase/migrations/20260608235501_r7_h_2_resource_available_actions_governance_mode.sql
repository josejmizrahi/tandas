-- R.7.H.2 — Wire _aa_apply_governance_mode en resource_available_actions
-- resources.canonical_owner_actor_id ES el contexto cuando es collective.
-- (no existe columna context_actor_id en resources; el owner canónico cumple el rol).

create or replace function public.resource_available_actions(p_resource_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_type text;
  v_owner uuid;
  v_rights text[];
  v_actions jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select resource_type, canonical_owner_actor_id
    into v_type, v_owner
    from public.resources where id = p_resource_id;
  if v_type is null then raise exception 'resource not found' using errcode = 'P0002'; end if;
  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;
  v_rights := public._actor_effective_rights(p_actor_id, p_resource_id);

  v_actions := coalesce((
    select jsonb_agg(jsonb_build_object(
      'action', a.action_key,
      'action_key', a.action_key,
      'label', a.display_name,
      'section', a.ui_section,
      'enabled', true,
      'reason', case
        when a.required_capability is not null and cardinality(a.required_rights) > 0
          then 'El recurso soporta ' || a.required_capability || ' y el actor tiene el derecho requerido'
        when a.required_capability is not null then 'El recurso soporta ' || a.required_capability
        else 'El actor tiene autoridad sobre el recurso' end,
      'required_rights', to_jsonb(a.required_rights),
      'required_capabilities', to_jsonb(
        case when a.required_capability is null then array[]::text[] else array[a.required_capability] end)
    ) order by a.sort_order, a.action_key)
    from public.resource_action_catalog a
    where (a.required_capability is null or public.resource_can(p_resource_id, a.required_capability))
      and (cardinality(a.required_rights) = 0 or a.required_rights && v_rights)
  ), '[]'::jsonb);

  return public._aa_apply_governance_mode(v_actions, v_owner);
end; $$;
