-- ============================================================================
-- F.CONTEXT.1 — Humanizar labels de context_available_actions
-- ============================================================================
-- F.CONTEXT.1 redefine el ContextHomeView como dashboard operativo. La sección
-- "Qué quieres hacer" (Quick Actions) debe usar lenguaje humano, no nombres de
-- primitivas técnicas. Doctrina F.2X: iOS NUNCA infiere labels — vienen del
-- backend verbatim. Esta migración cambia solamente los labels visibles
-- (label + reason) de la firma 2-arg; iOS no requiere cambio para recogerlos.
--
-- Cambios:
--   create_resource       "Crear recurso"   → "Agregar recurso"
--   create_event          "Crear evento"    → "Programar algo"
--   create_decision       "Crear decisión"  → "Crear propuesta"
--   record_expense        "Registrar gasto" → "Registrar movimiento"
--   create_rule           "Crear regla"     → "Definir automatización"
--   create_child_context  "Crear sub-contexto" → "Agregar subcontexto"
-- (invite_member ya es humano — no cambia)
-- ============================================================================

create or replace function public.context_available_actions(
  p_context_actor_id uuid,
  p_actor_id uuid
)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ctx public.actors%rowtype;
  v_is_member boolean;
  v_can_create_resource boolean;
  v_can_create_event boolean;
  v_can_create_decision boolean;
  v_can_record_money boolean;
  v_can_invite boolean;
  v_can_manage_rules boolean;
  v_can_manage_ctx boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ctx from public.actors where id = p_context_actor_id;
  if v_ctx.id is null then raise exception 'context not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  v_is_member          := public.is_context_member(p_context_actor_id);
  v_can_create_resource:= public.has_actor_authority(p_context_actor_id, p_actor_id, 'resources.create');
  v_can_create_event   := public.has_actor_authority(p_context_actor_id, p_actor_id, 'events.create');
  v_can_create_decision:= public.has_actor_authority(p_context_actor_id, p_actor_id, 'decisions.create');
  v_can_record_money   := public.has_actor_authority(p_context_actor_id, p_actor_id, 'money.record');
  v_can_invite         := public.has_actor_authority(p_context_actor_id, p_actor_id, 'context.invite');
  v_can_manage_rules   := public.has_actor_authority(p_context_actor_id, p_actor_id, 'rules.manage');
  v_can_manage_ctx     := public.has_actor_authority(p_context_actor_id, p_actor_id, 'context.manage');

  v_actions := v_actions || public._aa('create_resource', 'Agregar recurso', 'resources',
    v_can_create_resource,
    case when v_can_create_resource then 'Puedes sumar recursos a este contexto'
         else 'Requiere permiso resources.create' end);

  v_actions := v_actions || public._aa('create_event', 'Programar algo', 'calendar',
    v_can_create_event,
    case when v_can_create_event then 'Puedes programar eventos en este contexto'
         else 'Requiere permiso events.create' end);

  v_actions := v_actions || public._aa('create_decision', 'Crear propuesta', 'decisions',
    v_can_create_decision,
    case when v_can_create_decision then 'Puedes abrir propuestas para votar'
         else 'Requiere permiso decisions.create' end);

  v_actions := v_actions || public._aa('record_expense', 'Registrar movimiento', 'money',
    v_can_record_money,
    case when v_can_record_money then 'Puedes registrar gastos y movimientos'
         else 'Requiere permiso money.record' end);

  v_actions := v_actions || public._aa('invite_member', 'Invitar miembro', 'members',
    v_can_invite,
    case when v_can_invite then 'Puedes invitar a otra persona'
         else 'Requiere permiso context.invite' end);

  v_actions := v_actions || public._aa('create_rule', 'Definir automatización', 'rules',
    v_can_manage_rules,
    case when v_can_manage_rules then 'Puedes definir reglas que actúen automáticamente'
         else 'Requiere permiso rules.manage' end);

  if v_ctx.actor_kind <> 'person' then
    v_actions := v_actions || public._aa('create_child_context', 'Agregar subcontexto', 'hierarchy',
      v_can_manage_ctx,
      case when v_can_manage_ctx then 'Puedes organizar subcontextos dentro de este'
           else 'Requiere permiso context.manage' end);
  end if;

  return v_actions;
end; $$;

revoke all on function public.context_available_actions(uuid, uuid) from public, anon;
grant execute on function public.context_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.context_available_actions(uuid, uuid) is
  'F.CONTEXT.1: acciones canónicas a nivel contexto con labels humanizados (intent-first, F.2X).';

do $$
begin
  raise notice 'F.CONTEXT.1: humanized labels for context_available_actions';
end $$;
