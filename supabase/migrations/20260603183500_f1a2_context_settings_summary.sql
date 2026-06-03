-- F.1A-2 — context_settings_summary(p_context_actor_id)
-- Resumen único para la pantalla de Configuración del Contexto.
-- 10 secciones doctrinales (General/Miembros/Roles/Reglas/Decisiones/Dinero/
-- Reservaciones/Invitaciones/Auditoría) + available_actions gateadas por
-- has_actor_authority. Frontend NO calcula permisos.

CREATE OR REPLACE FUNCTION public.context_settings_summary(p_context_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_actor public.actors%rowtype;
  v_meta jsonb;
  v_member_count int;
  v_can_manage boolean;
  v_can_manage_members boolean;
  v_can_manage_rules boolean;
  v_can_invite boolean;
  v_can_view boolean;
  v_actions jsonb := '[]'::jsonb;
BEGIN
  IF v_caller IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;

  SELECT * INTO v_actor FROM public.actors WHERE id = p_context_actor_id;
  IF v_actor.id IS NULL THEN
    RAISE EXCEPTION 'context not found' USING errcode = 'P0002';
  END IF;
  IF v_actor.actor_kind = 'person' THEN
    RAISE EXCEPTION 'personal contexts have no settings (use personal_settings_summary)' USING errcode = '22023';
  END IF;
  IF NOT public.is_context_member(p_context_actor_id) THEN
    RAISE EXCEPTION 'not a member of context' USING errcode = '42501';
  END IF;

  v_meta := COALESCE(v_actor.metadata, '{}'::jsonb);

  SELECT count(*) INTO v_member_count
    FROM public.actor_memberships
   WHERE context_actor_id = p_context_actor_id AND membership_status = 'active';

  v_can_view          := public.has_actor_authority(p_context_actor_id, v_caller, 'context.view');
  v_can_manage        := public.has_actor_authority(p_context_actor_id, v_caller, 'context.manage');
  v_can_manage_members:= public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage');
  v_can_manage_rules  := public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage');
  v_can_invite        := public.has_actor_authority(p_context_actor_id, v_caller, 'context.invite');

  IF v_can_manage THEN
    v_actions := v_actions
      || '["edit_general","edit_decisions","edit_money","edit_reservations","edit_invitations","view_audit"]'::jsonb;
  END IF;
  IF v_can_manage_members THEN
    v_actions := v_actions || '["manage_members","manage_roles"]'::jsonb;
  END IF;
  IF v_can_manage_rules THEN
    v_actions := v_actions || '["manage_rules"]'::jsonb;
  END IF;
  IF v_can_invite THEN
    v_actions := v_actions || '["create_invite"]'::jsonb;
  END IF;
  IF v_can_view THEN
    v_actions := v_actions || '["view"]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'context_actor_id', p_context_actor_id,
    'general', jsonb_build_object(
      'display_name', v_actor.display_name,
      'description',  v_meta->>'description',
      'subtype',      v_actor.actor_subtype,
      'visibility',   v_actor.visibility,
      'member_count', v_member_count,
      'image_url',    v_meta->>'image_url'
    ),
    'decisions_config', jsonb_build_object(
      'default_voting_model', COALESCE(v_meta->'decisions_config'->>'default_voting_model', 'yes_no_abstain'),
      'quorum',               COALESCE(v_meta->'decisions_config'->>'quorum', 'simple_majority'),
      'majority_rule',        COALESCE(v_meta->'decisions_config'->>'majority_rule', 'simple')
    ),
    'money_config', jsonb_build_object(
      'currency',           COALESCE(v_meta->'money_config'->>'currency', 'MXN'),
      'default_split',      COALESCE(v_meta->'money_config'->>'default_split', 'equal'),
      'settlement_policy',  COALESCE(v_meta->'money_config'->>'settlement_policy', 'monthly')
    ),
    'reservations_config', jsonb_build_object(
      'priority_policy',       COALESCE(v_meta->'reservations_config'->>'priority_policy', 'least_recent_use_wins'),
      'conflict_resolution',   COALESCE(v_meta->'reservations_config'->>'conflict_resolution', 'community_vote'),
      'cancellation_policy',   COALESCE(v_meta->'reservations_config'->>'cancellation_policy', 'open')
    ),
    'invitations_config', jsonb_build_object(
      'who_can_invite',  COALESCE(v_meta->'invitations_config'->>'who_can_invite', 'admins'),
      'open_invites',    COALESCE((v_meta->'invitations_config'->>'open_invites')::boolean, false)
    ),
    'available_actions', v_actions
  );
END $$;

REVOKE EXECUTE ON FUNCTION public.context_settings_summary(uuid) FROM anon;
