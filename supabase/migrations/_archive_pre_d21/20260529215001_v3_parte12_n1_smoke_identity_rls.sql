-- PARTE 12 — N.1 Identity + RLS smoke (simulation approach)
--
-- Por qué simulamos en vez de SET ROLE:
--   1. Supabase prohibe SET ROLE dentro de SECURITY DEFINER (42501).
--   2. postgres + service_role tienen BYPASSRLS=true, así que correr el smoke
--      como SECURITY INVOKER tampoco fuerza enforcement de RLS.
--   3. No hay dblink/pg_background para abrir sub-sesión como `authenticated`.
--
-- Estrategia: validamos exactamente lo que rompería si PARTE 1 regresa:
--   (a) policy existe por nombre,
--   (b) RLS está habilitado en profiles,
--   (c) el USING expr evaluado contra (caller=A, target=X) da el resultado
--       esperado para X ∈ {A self, C co-member, B aislado},
--   (d) ninguna policy SELECT en profiles está concedida a `anon` → default deny.
--
-- Gap conocido: si alguien renombra/edita el USING pero la simulación
-- replica el mismo bug, no se detecta. Mitigado porque la simulación es
-- literal del USING declarado en mig PARTE 1.

CREATE OR REPLACE FUNCTION public._smoke_identity_rls()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_user_c       uuid := gen_random_uuid();
  v_group_ac     uuid;
  v_group_b      uuid;
  v_invite_c_id  uuid;
  v_invite_c_code text;
  v_policy_count int;
  v_rls_enabled  boolean;
  v_can_read     boolean;
  v_anon_policy_count int;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  -- 0. Policy presente.
  SELECT count(*) INTO v_policy_count
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname='public' AND c.relname='profiles' AND p.polname='profiles_select_self_or_co_member';
  step := '0.parte1_policy_present'; ok := v_policy_count = 1;
  detail := 'count=' || v_policy_count; RETURN NEXT;

  -- 0b. RLS habilitado en profiles.
  SELECT c.relrowsecurity INTO v_rls_enabled
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='profiles';
  step := '0b.rls_enabled_on_profiles'; ok := COALESCE(v_rls_enabled, false);
  detail := 'relrowsecurity=' || COALESCE(v_rls_enabled::text, 'NULL'); RETURN NEXT;

  -- Setup (bypassa RLS como postgres en SECURITY DEFINER).
  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_c);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke RLS A'),
    (v_user_b, 'Smoke RLS B'),
    (v_user_c, 'Smoke RLS C')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_ac := public.create_group('Smoke RLS AC ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');

  SELECT im.invite_id, im.code INTO v_invite_c_id, v_invite_c_code
    FROM public.invite_member(v_group_ac, 'smoke-rls-c@test', NULL, 'member', NULL) im;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_c::text)::text, true);
  PERFORM public.accept_invite(v_invite_c_code);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  v_group_b := public.create_group('Smoke RLS B ' || substr(v_user_b::text,1,8), NULL, 'friends', 'Smoke');

  -- Simulación: caller = A.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  -- N.1.1: target = A (self) → policy USING → true.
  SELECT (v_user_a = auth.uid()) OR EXISTS (
    SELECT 1 FROM public.group_memberships gm2
    WHERE gm2.user_id = v_user_a
      AND gm2.group_id IN (
        SELECT gm1.group_id FROM public.group_memberships gm1
        WHERE gm1.user_id = auth.uid() AND gm1.status IN ('active','provisional')
      )
      AND gm2.status IN ('active','provisional')
  ) INTO v_can_read;
  step := 'N.1.1.self_profile_visible'; ok := v_can_read;
  detail := 'policy_using=' || v_can_read::text; RETURN NEXT;

  -- N.1.3: target = C (co-member en group_ac) → policy USING → true.
  SELECT (v_user_c = auth.uid()) OR EXISTS (
    SELECT 1 FROM public.group_memberships gm2
    WHERE gm2.user_id = v_user_c
      AND gm2.group_id IN (
        SELECT gm1.group_id FROM public.group_memberships gm1
        WHERE gm1.user_id = auth.uid() AND gm1.status IN ('active','provisional')
      )
      AND gm2.status IN ('active','provisional')
  ) INTO v_can_read;
  step := 'N.1.3.co_member_profile_visible'; ok := v_can_read;
  detail := 'policy_using=' || v_can_read::text; RETURN NEXT;

  -- N.1.2: target = B (aislado en group_b) → policy USING → false.
  SELECT (v_user_b = auth.uid()) OR EXISTS (
    SELECT 1 FROM public.group_memberships gm2
    WHERE gm2.user_id = v_user_b
      AND gm2.group_id IN (
        SELECT gm1.group_id FROM public.group_memberships gm1
        WHERE gm1.user_id = auth.uid() AND gm1.status IN ('active','provisional')
      )
      AND gm2.status IN ('active','provisional')
  ) INTO v_can_read;
  step := 'N.1.2.isolated_profile_invisible'; ok := NOT v_can_read;
  detail := 'policy_using=' || v_can_read::text; RETURN NEXT;

  -- N.1.4: ninguna policy SELECT en profiles concedida a `anon`.
  --        Combinado con RLS habilitado (0b) → default deny para anon.
  SELECT count(*) INTO v_anon_policy_count
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  WHERE c.relname='profiles' AND p.polcmd='r' AND 'anon'::regrole = ANY(p.polroles);
  step := 'N.1.4.anon_no_select_policy'; ok := v_anon_policy_count = 0;
  detail := 'anon_select_policies=' || v_anon_policy_count; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_identity_rls() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_identity_rls() TO service_role;
