-- PARTE 12 — N.12 Cross-tenant isolation smoke.
--
-- Modelo: A es active member de group_x. B es active member de group_y.
-- A intenta operar sobre group_y desde 5 RPCs canónicas distintas — todas
-- deben raise por assert_member_of_group / assert_permission / RLS chain.
--
-- DEFERIDOS: tests de RLS directa (SELECT FROM table WHERE group_id=Y)
-- — mismos límites que N.1 (SET ROLE bloqueado en SECURITY DEFINER +
-- postgres BYPASSRLS). Cubierto vía simulation/policy presence en N.1.

CREATE OR REPLACE FUNCTION public._smoke_cross_tenant_guards()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_group_x      uuid;
  v_group_y      uuid;
  v_membership_a_x uuid;
  v_membership_b_y uuid;
  v_expense_blocked boolean := false;
  v_recent_blocked  boolean := false;
  v_invite_blocked  boolean := false;
  v_decision_rules_blocked boolean := false;
  v_assert_blocked  boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke Tnt A'), (v_user_b, 'Smoke Tnt B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke Tnt X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  v_group_y := public.create_group('Smoke Tnt Y ' || substr(v_user_b::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_b_y FROM public.group_memberships gm
   WHERE gm.group_id = v_group_y AND gm.user_id = v_user_b;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  BEGIN
    PERFORM public.record_expense(
      p_group_id              => v_group_y,
      p_resource_id           => NULL,
      p_amount                => 50,
      p_unit                  => 'MXN',
      p_paid_by_membership_id => v_membership_b_y,
      p_description           => 'cross-tenant attempt',
      p_split_mode            => 'even',
      p_split_breakdown       => jsonb_build_array(
                                    jsonb_build_object('membership_id', v_membership_b_y)
                                  ),
      p_in_kind               => false,
      p_mandate_id            => NULL,
      p_client_id             => 'smoke-tnt-exp-' || substr(v_user_a::text,1,8)
    );
  EXCEPTION WHEN OTHERS THEN
    v_expense_blocked := true;
  END;
  step := 'N.12.1.record_expense_cross_tenant_blocked'; ok := v_expense_blocked;
  detail := 'blocked=' || v_expense_blocked::text; RETURN NEXT;

  BEGIN
    PERFORM count(*) FROM public.group_events_recent(v_group_y, 10, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_recent_blocked := true;
  END;
  step := 'N.12.2.group_events_recent_cross_tenant_blocked'; ok := v_recent_blocked;
  detail := 'blocked=' || v_recent_blocked::text; RETURN NEXT;

  BEGIN
    PERFORM public.invite_member(v_group_y, 'cross-tnt@test', NULL, 'member', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_invite_blocked := true;
  END;
  step := 'N.12.3.invite_member_cross_tenant_blocked'; ok := v_invite_blocked;
  detail := 'blocked=' || v_invite_blocked::text; RETURN NEXT;

  BEGIN
    PERFORM public.set_decision_rules(v_group_y, 'majority', 2, 'cross attempt', 'majority', 'majority');
  EXCEPTION WHEN OTHERS THEN
    v_decision_rules_blocked := true;
  END;
  step := 'N.12.4.set_decision_rules_cross_tenant_blocked'; ok := v_decision_rules_blocked;
  detail := 'blocked=' || v_decision_rules_blocked::text; RETURN NEXT;

  BEGIN
    PERFORM public.assert_permission(v_group_y, 'group.update');
  EXCEPTION WHEN OTHERS THEN
    v_assert_blocked := true;
  END;
  step := 'N.12.5.assert_permission_cross_tenant_blocked'; ok := v_assert_blocked;
  detail := 'blocked=' || v_assert_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_cross_tenant_guards() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_cross_tenant_guards() TO service_role;
