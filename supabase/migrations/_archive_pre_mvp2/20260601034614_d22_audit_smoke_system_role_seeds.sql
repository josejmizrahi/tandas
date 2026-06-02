-- Smoke: verify the 3 system roles are seeded consistently across all
-- existing groups + the 5 constitutional perms are admin-excluded.

CREATE OR REPLACE FUNCTION public._smoke_system_role_seeds()
RETURNS TABLE(check_name text, status text, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_catalog_total      integer;
  v_founder_min        integer;
  v_founder_max        integer;
  v_admin_min          integer;
  v_admin_max          integer;
  v_member_min         integer;
  v_member_max         integer;
  v_admin_constitutional integer;
  v_member_has_culture integer;
  v_member_has_decisions_create integer;
  v_groups_total       integer;
BEGIN
  SELECT COUNT(*) INTO v_catalog_total FROM permissions;
  SELECT COUNT(*) INTO v_groups_total
    FROM group_roles gr WHERE gr.key='founder' AND gr.is_system=true;

  -- Founder = 100% del catálogo
  SELECT MIN(c), MAX(c) INTO v_founder_min, v_founder_max
    FROM (SELECT (SELECT COUNT(*) FROM group_role_permissions grp WHERE grp.role_id=gr.id) AS c
          FROM group_roles gr WHERE gr.key='founder' AND gr.is_system=true) s;
  IF v_founder_min = v_catalog_total AND v_founder_max = v_catalog_total THEN
    check_name:='T1_founder_all_catalog'; status:='PASS';
    detail:=v_founder_min||'/'||v_catalog_total||' perms across '||v_groups_total||' groups';
  ELSE
    check_name:='T1_founder_all_catalog'; status:='FAIL';
    detail:='min='||v_founder_min||' max='||v_founder_max||' want '||v_catalog_total;
  END IF;
  RETURN NEXT;

  -- Admin = catalog - 5 constitutional
  SELECT MIN(c), MAX(c) INTO v_admin_min, v_admin_max
    FROM (SELECT (SELECT COUNT(*) FROM group_role_permissions grp WHERE grp.role_id=gr.id) AS c
          FROM group_roles gr WHERE gr.key='admin' AND gr.is_system=true) s;
  IF v_admin_min = (v_catalog_total - 5) AND v_admin_max = (v_catalog_total - 5) THEN
    check_name:='T2_admin_minus_5_constitutional'; status:='PASS';
    detail:=v_admin_min||'/'||(v_catalog_total - 5)||' perms (= catalog - 5 constitutional) across '||v_groups_total||' groups';
  ELSE
    check_name:='T2_admin_minus_5_constitutional'; status:='FAIL';
    detail:='min='||v_admin_min||' max='||v_admin_max||' want '||(v_catalog_total - 5);
  END IF;
  RETURN NEXT;

  -- Admin should NOT have any of the 5 constitutional perms
  SELECT COUNT(*) INTO v_admin_constitutional
    FROM group_role_permissions grp
    JOIN group_roles gr ON gr.id=grp.role_id
   WHERE gr.key='admin' AND gr.is_system=true
     AND grp.permission_key IN (
       'engine.toggle','group.archive','group.dissolve','group.update','roles.manage'
     );
  IF v_admin_constitutional = 0 THEN
    check_name:='T3_admin_no_constitutional'; status:='PASS';
    detail:='0 admin rows have any of the 5 constitutional perms';
  ELSE
    check_name:='T3_admin_no_constitutional'; status:='FAIL';
    detail:=v_admin_constitutional||' admin rows leaked constitutional perm';
  END IF;
  RETURN NEXT;

  -- Member range: 15 perms (was 14, +2 culture = 15. Hotfix decisions.create already counted.)
  SELECT MIN(c), MAX(c) INTO v_member_min, v_member_max
    FROM (SELECT (SELECT COUNT(*) FROM group_role_permissions grp WHERE grp.role_id=gr.id) AS c
          FROM group_roles gr WHERE gr.key='member' AND gr.is_system=true) s;
  IF v_member_min = v_member_max AND v_member_min >= 15 THEN
    check_name:='T4_member_canonical_count'; status:='PASS';
    detail:=v_member_min||' perms uniform across '||v_groups_total||' groups';
  ELSE
    check_name:='T4_member_canonical_count'; status:='FAIL';
    detail:='min='||v_member_min||' max='||v_member_max;
  END IF;
  RETURN NEXT;

  -- Member must have decisions.create (D.22 doctrine #4)
  SELECT COUNT(DISTINCT gr.id) INTO v_member_has_decisions_create
    FROM group_roles gr
    WHERE gr.key='member' AND gr.is_system=true
      AND EXISTS (
        SELECT 1 FROM group_role_permissions grp
         WHERE grp.role_id=gr.id AND grp.permission_key='decisions.create'
      );
  IF v_member_has_decisions_create = v_groups_total THEN
    check_name:='T5_member_has_decisions_create'; status:='PASS';
    detail:='all '||v_groups_total||' member roles can SOLICITAR (open decision)';
  ELSE
    check_name:='T5_member_has_decisions_create'; status:='FAIL';
    detail:=v_member_has_decisions_create||'/'||v_groups_total||' member roles missing decisions.create';
  END IF;
  RETURN NEXT;

  -- Member must have culture.propose + culture.endorse
  SELECT COUNT(DISTINCT gr.id) INTO v_member_has_culture
    FROM group_roles gr
    WHERE gr.key='member' AND gr.is_system=true
      AND EXISTS (
        SELECT 1 FROM group_role_permissions grp
         WHERE grp.role_id=gr.id AND grp.permission_key='culture.propose'
      )
      AND EXISTS (
        SELECT 1 FROM group_role_permissions grp
         WHERE grp.role_id=gr.id AND grp.permission_key='culture.endorse'
      );
  IF v_member_has_culture = v_groups_total THEN
    check_name:='T6_member_has_culture_perms'; status:='PASS';
    detail:='all '||v_groups_total||' member roles can propose+endorse norms';
  ELSE
    check_name:='T6_member_has_culture_perms'; status:='FAIL';
    detail:=v_member_has_culture||'/'||v_groups_total||' member roles missing culture perms';
  END IF;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._smoke_system_role_seeds() FROM PUBLIC;
