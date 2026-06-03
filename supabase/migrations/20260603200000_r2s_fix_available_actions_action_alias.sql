-- ============================================================================
-- R.2S-FIX-2 — available_actions retrocompatible (action + action_key)
-- ============================================================================
-- El iOS shippeado (RuulCore.ResourceAvailableAction) decodifica `action`
-- (no-opcional). R.2S-FIX migró la forma canónica a `action_key`, lo que rompió
-- el decoding de resource_detail (y cualquier vista que renderice acciones):
-- "algo salió mal".
--
-- Fix retrocompatible: cada action object emite AMBAS llaves —
--   action (= action_key, para la app actual) + action_key (contrato canónico).
-- Los campos extra (enabled/reason/required_*) los ignora el decoder de iOS.
-- ============================================================================

-- ── builder _aa: agrega 'action' = action_key (obligation/decision/reservation)
create or replace function public._aa(
  p_action_key text,
  p_label text,
  p_section text,
  p_enabled boolean,
  p_reason text,
  p_required_rights text[] default '{}',
  p_required_capabilities text[] default '{}'
)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'action', p_action_key,           -- compat iOS (ResourceAvailableAction.action)
    'action_key', p_action_key,       -- canónico
    'label', p_label,
    'section', p_section,
    'enabled', p_enabled,
    'reason', p_reason,
    'required_rights', to_jsonb(coalesce(p_required_rights, '{}')),
    'required_capabilities', to_jsonb(coalesce(p_required_capabilities, '{}')));
$$;

revoke all on function public._aa(text, text, text, boolean, text, text[], text[]) from public, anon;
grant execute on function public._aa(text, text, text, boolean, text, text[], text[]) to authenticated, service_role;

-- ── resource_available_actions(actor-aware): agrega 'action' = action_key
create or replace function public.resource_available_actions(p_resource_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_type text;
  v_rights text[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select resource_type into v_type from public.resources where id = p_resource_id;
  if v_type is null then raise exception 'resource not found' using errcode = 'P0002'; end if;
  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  v_rights := public._actor_effective_rights(p_actor_id, p_resource_id);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'action', a.action_key,          -- compat iOS
      'action_key', a.action_key,      -- canónico
      'label', a.display_name,
      'section', a.ui_section,
      'enabled', true,
      'reason', case
        when a.required_capability is not null and cardinality(a.required_rights) > 0
          then 'El recurso soporta ' || a.required_capability || ' y el actor tiene el derecho requerido'
        when a.required_capability is not null
          then 'El recurso soporta ' || a.required_capability
        else 'El actor tiene autoridad sobre el recurso' end,
      'required_rights', to_jsonb(a.required_rights),
      'required_capabilities', to_jsonb(
        case when a.required_capability is null then array[]::text[]
             else array[a.required_capability] end)
    ) order by a.sort_order, a.action_key)
    from public.resource_action_catalog a
    where (a.required_capability is null
           or public.resource_can(p_resource_id, a.required_capability))
      and (cardinality(a.required_rights) = 0
           or a.required_rights && v_rights)
  ), '[]'::jsonb);
end; $$;

revoke all on function public.resource_available_actions(uuid, uuid) from public, anon;
grant execute on function public.resource_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.resource_available_actions(uuid, uuid) is
  'R.2S-FIX-2: acciones actor-aware con forma retrocompatible (action + action_key).';
