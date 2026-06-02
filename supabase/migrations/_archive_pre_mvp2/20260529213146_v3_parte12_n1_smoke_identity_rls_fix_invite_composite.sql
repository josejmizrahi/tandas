-- PARTE 12 — N.1 fix: invite_member ahora retorna TABLE(invite_id, code, placeholder_membership_id)
-- post-PARTE INV. Adapto la llamada a SELECT INTO sobre el composite.

CREATE OR REPLACE FUNCTION public._smoke_identity_rls()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();  -- aislado en su propio grupo
  v_user_c       uuid := gen_random_uuid();  -- co-member de A en group_ac
  v_group_ac     uuid;
  v_group_b      uuid;
  v_invite_c_id  uuid;
  v_invite_c_code text;
  v_policy_count int;
  v_n_rows       int;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups in db (%)', (SELECT count(*) FROM public.groups);
  END IF;

  -- 0. Precheck: PARTE 1 policy debe estar viva.
  SELECT count(*) INTO v_policy_count
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname = 'profiles' AND p.polname = 'profiles_select_self_or_co_member';
  step := '0.parte1_policy_present'; ok := v_policy_count = 1;
  detail := 'policy_rows=' || v_policy_count; RETURN NEXT;

  -- Setup (corre como postgres → bypassa RLS, OK para fixture).
  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_c);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke RLS A'),
    (v_user_b, 'Smoke RLS B'),
    (v_user_c, 'Smoke RLS C')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  -- A crea group_ac, invita a C, C acepta.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_ac := public.create_group('Smoke RLS AC ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');

  SELECT im.invite_id, im.code INTO v_invite_c_id, v_invite_c_code
    FROM public.invite_member(v_group_ac, 'smoke-rls-c@test', NULL, 'member', NULL) im;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_c::text)::text, true);
  PERFORM public.accept_invite(v_invite_c_code);

  -- B crea group_b (aislado de A y C).
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  v_group_b := public.create_group('Smoke RLS B ' || substr(v_user_b::text,1,8), NULL, 'friends', 'Smoke');

  -- N.1.1: A authenticated lee su propio profile → 1 row.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n_rows FROM public.profiles WHERE id = v_user_a;
  step := 'N.1.1.self_profile_visible'; ok := v_n_rows = 1;
  detail := 'rows=' || v_n_rows; RETURN NEXT;

  -- N.1.3: A authenticated lee profile de C (co-member en group_ac) → 1 row.
  SELECT count(*) INTO v_n_rows FROM public.profiles WHERE id = v_user_c;
  step := 'N.1.3.co_member_profile_visible'; ok := v_n_rows = 1;
  detail := 'rows=' || v_n_rows; RETURN NEXT;

  -- N.1.2: A authenticated NO lee profile de B (aislado en group_b) → 0 rows.
  SELECT count(*) INTO v_n_rows FROM public.profiles WHERE id = v_user_b;
  step := 'N.1.2.isolated_profile_invisible'; ok := v_n_rows = 0;
  detail := 'rows=' || v_n_rows; RETURN NEXT;

  RESET ROLE;

  -- N.1.4: anon (sin JWT) NO lee profiles → 0 rows.
  PERFORM set_config('request.jwt.claims', NULL, true);
  SET LOCAL ROLE anon;
  SELECT count(*) INTO v_n_rows FROM public.profiles WHERE id = v_user_a;
  step := 'N.1.4.anon_blocked'; ok := v_n_rows = 0;
  detail := 'rows=' || v_n_rows; RETURN NEXT;

  RESET ROLE;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_identity_rls() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_identity_rls() TO service_role;
