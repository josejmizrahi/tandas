-- R.7.D — F.2X descriptor extension: mode opcional + member_available_actions
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md §5.2 + §11 (camino B firmado)
-- Mandato founder 2026-06-08:
--   1. _aa_apply_governance_mode helper
--   2. Wire en context_available_actions (sin cambiar action_keys actuales)
--   3. member_available_actions(ctx, member, actor) — primera surface real
--   4-7. Restricciones: solo 3 acciones, no self-remove, no promote-if-admin
-- PULL sigue siendo modelo principal; mode='request_decision' solo señaliza a iOS.
-- Otros 5 descriptors (resource/event/decision/obligation/list_resource_actions)
-- quedan en R.7.D.fix-up cuando emitan action_keys del catalog.

-- §1 — Helper: decora actions[] con mode si action_key matches catalog + requires_decision
create or replace function public._aa_apply_governance_mode(
  p_actions jsonb,
  p_context_actor_id uuid
) returns jsonb language sql stable as $$
  select coalesce(
    (select jsonb_agg(
      case
        when gac.action_key is not null
         and (
           coalesce(public.governance_policy(p_context_actor_id, gac.policy_key), 'null'::jsonb) = 'true'::jsonb
           or (
             coalesce(public.governance_policy(p_context_actor_id, gac.policy_key), 'null'::jsonb) = 'null'::jsonb
             and gac.default_requires_decision
           )
         )
        then action || jsonb_build_object('mode', 'request_decision')
        else action
      end
      order by ord
    )
    from jsonb_array_elements(coalesce(p_actions,'[]'::jsonb)) with ordinality as t(action, ord)
    left join public.governance_action_catalog gac
      on gac.action_key = public._governance_action_resolve(action->>'action_key')),
    coalesce(p_actions,'[]'::jsonb)
  );
$$;

comment on function public._aa_apply_governance_mode(jsonb, uuid) is
  'R.7.D — Helper F.2X. Decora cada entry de available_actions[] con mode=request_decision si su action_key matchea governance_action_catalog AND (policy_key=true en contexto OR catalog.default_requires_decision=true). Entries sin match en catalog quedan SIN mode (iOS asume direct). Backwards compat total: si actions[] no contiene action_keys del catalog, devuelve actions[] sin cambios.';

-- §2 — Wire helper en context_available_actions
create or replace function public.context_available_actions(p_context_actor_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ctx public.actors%rowtype;
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

  return public._aa_apply_governance_mode(v_actions, p_context_actor_id);
end;
$$;

-- §3 — member_available_actions (NEW: primera surface real con action_keys del catalog)
create or replace function public.member_available_actions(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_actor_id uuid
) returns jsonb
language plpgsql stable security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_can_manage_members boolean;
  v_member_active boolean;
  v_member_is_admin boolean;
  v_is_self boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  v_can_manage_members := public.has_actor_authority(p_context_actor_id, p_actor_id, 'members.manage');
  v_is_self := (p_actor_id = p_member_actor_id);

  select exists (
    select 1 from public.actor_memberships
    where context_actor_id = p_context_actor_id
      and member_actor_id = p_member_actor_id
      and membership_status = 'active'
  ) into v_member_active;

  select exists (
    select 1
    from public.role_assignments ra
    join public.roles r on r.id = ra.role_id
    where ra.context_actor_id = p_context_actor_id
      and ra.member_actor_id = p_member_actor_id
      and r.role_key in ('admin','founder','owner')
      and (ra.ends_at is null or ra.ends_at > now())
  ) into v_member_is_admin;

  if not v_is_self and v_member_active then
    v_actions := v_actions || public._aa(
      'member.remove',
      'Remover del contexto',
      'membership',
      v_can_manage_members,
      case when v_can_manage_members then 'Puedes remover a este miembro del contexto'
           else 'Requiere permiso members.manage' end
    );
  end if;

  if v_member_active then
    v_actions := v_actions || public._aa(
      'member.pause',
      'Pausar miembro',
      'membership',
      v_can_manage_members,
      case when v_can_manage_members then 'Puedes pausar la membresía temporalmente'
           else 'Requiere permiso members.manage' end
    );
  end if;

  if v_member_active and not v_member_is_admin then
    v_actions := v_actions || public._aa(
      'member.promote',
      'Promover a admin',
      'membership',
      v_can_manage_members,
      case when v_can_manage_members then 'Puedes promover a este miembro a admin'
           else 'Requiere permiso members.manage' end
    );
  end if;

  return public._aa_apply_governance_mode(v_actions, p_context_actor_id);
end;
$$;

grant execute on function public.member_available_actions(uuid, uuid, uuid) to authenticated;

comment on function public.member_available_actions(uuid, uuid, uuid) is
  'R.7.D — F.2X descriptor para acciones membership-level. Devuelve hasta 3 actions (member.remove, member.pause, member.promote) con mode=request_decision por default (catalog.default_requires_decision=true para los 3). Reglas: member.remove no aparece si target=caller (founder mandato #6); member.promote no aparece si target ya es admin/founder/owner (founder mandato #7).';
