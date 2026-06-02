-- D.22 hotfix doctrinal: member role debe poder abrir decisiones.
-- Doctrine D.22 #4: "member solicita acciones críticas (abre decisión)".
-- Drift detectado en FASE E smoke: 73 grupos con member role sin decisions.create.

-- 1. Backfill existing member roles.
INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT gr.id, 'decisions.create'
  FROM public.group_roles gr
 WHERE gr.key = 'member' AND gr.is_system = true
   AND NOT EXISTS (
     SELECT 1 FROM public.group_role_permissions grp
      WHERE grp.role_id = gr.id AND grp.permission_key = 'decisions.create'
   )
ON CONFLICT DO NOTHING;

-- 2. Update create_group seed for new groups.
CREATE OR REPLACE FUNCTION public.create_group(
  p_name text,
  p_slug text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_purpose_declared text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_group_id        uuid;
  v_membership_id   uuid;
  v_founder_role_id uuid;
  v_member_role_id  uuid;
BEGIN
  INSERT INTO public.groups (name, slug, category, created_by, purpose_summary)
  VALUES (p_name, p_slug, p_category, auth.uid(), p_purpose_declared)
  RETURNING id INTO v_group_id;

  INSERT INTO public.group_memberships (group_id, user_id, status, membership_type, joined_at, joined_via)
  VALUES (v_group_id, auth.uid(), 'active', 'member', now(), 'founder_seed')
  RETURNING id INTO v_membership_id;

  INSERT INTO public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  VALUES (v_group_id, v_membership_id, auth.uid(), 'joined', 'founder_seed');

  INSERT INTO public.group_roles (group_id, key, name, description, is_system, is_default) VALUES
    (v_group_id, 'founder', 'Fundador',     'Autoridad fundacional', true, false),
    (v_group_id, 'admin',   'Administrador','Gestión operativa',     true, false),
    (v_group_id, 'member',  'Miembro',      'Pertenencia plena',     true, true)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_founder_role_id FROM public.group_roles WHERE group_id = v_group_id AND key = 'founder';
  SELECT id INTO v_member_role_id  FROM public.group_roles WHERE group_id = v_group_id AND key = 'member';

  INSERT INTO public.group_role_permissions (role_id, permission_key)
  SELECT v_founder_role_id, key FROM public.permissions
  ON CONFLICT DO NOTHING;

  INSERT INTO public.group_role_permissions (role_id, permission_key) VALUES
    (v_member_role_id, 'group.read'),
    (v_member_role_id, 'members.read'),
    (v_member_role_id, 'rules.read'),
    (v_member_role_id, 'resources.read'),
    (v_member_role_id, 'rsvp.submit'),
    (v_member_role_id, 'check_in.submit'),
    (v_member_role_id, 'expense.record'),
    (v_member_role_id, 'contribution.record'),
    (v_member_role_id, 'settlement.record'),
    (v_member_role_id, 'decisions.vote'),
    (v_member_role_id, 'decisions.create'),  -- D.22: members can SOLICITAR
    (v_member_role_id, 'disputes.open'),
    (v_member_role_id, 'records.read')
  ON CONFLICT DO NOTHING;

  INSERT INTO public.group_member_roles (membership_id, role_id, assigned_by)
  VALUES (v_membership_id, v_founder_role_id, auth.uid());

  IF p_purpose_declared IS NOT NULL AND length(p_purpose_declared) > 0 THEN
    INSERT INTO public.group_purposes (group_id, kind, body, created_by)
    VALUES (v_group_id, 'declared', p_purpose_declared, auth.uid());
  END IF;

  INSERT INTO public.group_events (group_id, actor_user_id, event_type, entity_kind, entity_id, summary)
  VALUES (v_group_id, auth.uid(), 'group.created', 'group', v_group_id, 'Grupo creado');

  RETURN v_group_id;
END;
$$;
