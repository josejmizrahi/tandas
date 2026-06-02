-- D.22 audit fixes: admin role was empty in 73/73 groups; member rol
-- lacks `culture.propose` + `culture.endorse`. Backfill + update
-- create_group seed so future groups land coherent.
--
-- Admin perms doctrine (D.22 #5): "solicitar/ejecutar operativas,
-- NO cambios constitucionales". So admin gets EVERYTHING in the
-- catalog EXCEPT the 5 constitutional perms:
--   - engine.toggle
--   - group.archive
--   - group.dissolve
--   - group.update         (boundary/visibility constitucional)
--   - roles.manage         (META — gestión de roles/perms)
--
-- Member additionally gets cultural perms (propose + endorse).
-- Founder is unchanged (already has 100%).

-- ===================================================================
-- 1. Backfill admin role perms in all 73 existing groups
-- ===================================================================
INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT gr.id, p.key
  FROM public.group_roles gr
  CROSS JOIN public.permissions p
 WHERE gr.key = 'admin' AND gr.is_system = true
   AND p.key NOT IN (
     'engine.toggle',
     'group.archive',
     'group.dissolve',
     'group.update',
     'roles.manage'
   )
ON CONFLICT DO NOTHING;

-- ===================================================================
-- 2. Backfill culture.propose + culture.endorse on member system role
-- ===================================================================
INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT gr.id, perm.key
  FROM public.group_roles gr
  CROSS JOIN (VALUES ('culture.propose'), ('culture.endorse')) AS perm(key)
 WHERE gr.key = 'member' AND gr.is_system = true
ON CONFLICT DO NOTHING;

-- ===================================================================
-- 3. Update create_group seed so new groups get admin + member right
-- ===================================================================
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
  v_admin_role_id   uuid;
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
    (v_group_id, 'founder', 'Fundador',      'Autoridad fundacional', true, false),
    (v_group_id, 'admin',   'Administrador', 'Gestión operativa',     true, false),
    (v_group_id, 'member',  'Miembro',       'Pertenencia plena',     true, true)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_founder_role_id FROM public.group_roles WHERE group_id = v_group_id AND key = 'founder';
  SELECT id INTO v_admin_role_id   FROM public.group_roles WHERE group_id = v_group_id AND key = 'admin';
  SELECT id INTO v_member_role_id  FROM public.group_roles WHERE group_id = v_group_id AND key = 'member';

  -- Founder: 100% del catálogo.
  INSERT INTO public.group_role_permissions (role_id, permission_key)
  SELECT v_founder_role_id, key FROM public.permissions
  ON CONFLICT DO NOTHING;

  -- Admin: todo MENOS las 5 constitucionales.
  INSERT INTO public.group_role_permissions (role_id, permission_key)
  SELECT v_admin_role_id, key FROM public.permissions
  WHERE key NOT IN (
    'engine.toggle',
    'group.archive',
    'group.dissolve',
    'group.update',
    'roles.manage'
  )
  ON CONFLICT DO NOTHING;

  -- Member: read + acciones personales + solicitar decisiones + cultura.
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
    (v_member_role_id, 'decisions.create'),
    (v_member_role_id, 'disputes.open'),
    (v_member_role_id, 'records.read'),
    (v_member_role_id, 'culture.propose'),
    (v_member_role_id, 'culture.endorse')
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
