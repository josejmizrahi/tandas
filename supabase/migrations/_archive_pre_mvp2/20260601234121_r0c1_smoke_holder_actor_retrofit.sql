-- R.0C.1 MIG 2 — Smoke for holder_actor_id retrofit (final fixed version).
--
-- Consolidación: las 4 iteraciones intermedias (parent_type fix → whitelist fix →
-- PK fix) se agruparon aquí. Cada iteración descubrió un constraint pre-existente
-- de la tabla resource_rights que conviene documentar para R.0C.2:
--   1) `assert_resource_type` enforces parent resource.resource_type='right'
--      (la tabla es subtype, no universal rights)
--   2) `right_kind` whitelist = {access, membership, seat, benefit, other}
--      (NO incluye OWN/USE/MANAGE/etc del universal rights doctrine)
--   3) PK = (resource_id) alone, no (resource_id, right_kind)
--      (max 1 right per resource — 1:1 subtype)
--
-- Esos 3 constraints son blockers para que resource_rights sea el universal rights
-- table. R.0C.2 deberá decidir: migrar este esquema o crear nueva tabla.
--
-- Casos:
--  1) Existing rights backfilleados verificados
--  2) INSERT via compat view con solo holder_membership_id → trigger deriva
--  3) INSERT via compat view con holder_actor_id explícito → preservado
--  4) INSERT directo en resource_rights con holder_actor_id sin membership → permitido
--  5) UPDATE holder_membership_id → trigger re-deriva holder_actor_id

CREATE OR REPLACE FUNCTION public._smoke_r0c1_holder_actor_retrofit()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group        uuid;
  v_user_a       uuid;
  v_user_b       uuid;
  v_membership_a uuid;
  v_membership_b uuid;
  v_resource_a   uuid;
  v_resource_b   uuid;
  v_resource_c   uuid;
  v_derived      uuid;
  v_explicit     uuid;
  v_direct       uuid;
  v_re_derived   uuid;
BEGIN
  SELECT id INTO v_group FROM public.groups
   WHERE id IN (SELECT group_id FROM public.group_memberships GROUP BY group_id HAVING count(*) >= 2)
   LIMIT 1;
  IF v_group IS NULL THEN
    RAISE EXCEPTION '_smoke_r0c1: no group with >=2 memberships';
  END IF;

  SELECT id, user_id INTO v_membership_a, v_user_a FROM public.group_memberships
   WHERE group_id = v_group LIMIT 1;
  SELECT id, user_id INTO v_membership_b, v_user_b FROM public.group_memberships
   WHERE group_id = v_group AND id <> v_membership_a LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('ruul.resource_create_intent', '', true);

  -- ===== Caso 1: Existing rights backfilleados =====
  IF EXISTS (
    SELECT 1 FROM public.resource_rights rr
    JOIN public.group_memberships gm ON gm.id = rr.holder_membership_id
    WHERE rr.holder_membership_id IS NOT NULL
      AND (rr.holder_actor_id IS DISTINCT FROM gm.user_id)
  ) THEN
    RAISE EXCEPTION '_smoke_r0c1 Caso1: backfill mismatch';
  END IF;

  -- Setup: 3 parent resources type='right' (PK resource_id en resource_rights = 1:1)
  INSERT INTO public.resources
    (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'right', '_smoke_r0c1 res A', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user_a)
  RETURNING id INTO v_resource_a;

  INSERT INTO public.resources
    (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'right', '_smoke_r0c1 res B', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user_a)
  RETURNING id INTO v_resource_b;

  INSERT INTO public.resources
    (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'right', '_smoke_r0c1 res C', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user_a)
  RETURNING id INTO v_resource_c;

  -- ===== Caso 2: INSERT con solo membership → trigger deriva =====
  INSERT INTO public.group_resource_rights
    (resource_id, right_kind, holder_membership_id, granted_at, transferable)
  VALUES
    (v_resource_a, 'access', v_membership_a, now(), false);

  SELECT holder_actor_id INTO v_derived
    FROM public.resource_rights WHERE resource_id = v_resource_a;
  IF v_derived IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION '_smoke_r0c1 Caso2: derived holder = % (got %)',
      v_user_a::text, COALESCE(v_derived::text,'NULL');
  END IF;

  -- ===== Caso 3: INSERT con holder_actor_id explícito → preservado =====
  INSERT INTO public.group_resource_rights
    (resource_id, right_kind, holder_membership_id, holder_actor_id, granted_at, transferable)
  VALUES
    (v_resource_b, 'membership', v_membership_a, v_user_b, now(), false);

  SELECT holder_actor_id INTO v_explicit
    FROM public.resource_rights WHERE resource_id = v_resource_b;
  IF v_explicit IS DISTINCT FROM v_user_b THEN
    RAISE EXCEPTION '_smoke_r0c1 Caso3: explicit holder preserved = % (got %)',
      v_user_b::text, COALESCE(v_explicit::text,'NULL');
  END IF;

  -- ===== Caso 4: INSERT directo sin membership =====
  INSERT INTO public.resource_rights
    (resource_id, right_kind, holder_membership_id, holder_actor_id, granted_at, transferable)
  VALUES
    (v_resource_c, 'seat', NULL, v_user_b, now(), false);

  SELECT holder_actor_id INTO v_direct
    FROM public.resource_rights WHERE resource_id = v_resource_c;
  IF v_direct IS DISTINCT FROM v_user_b THEN
    RAISE EXCEPTION '_smoke_r0c1 Caso4: direct holder = % (got %)',
      v_user_b::text, COALESCE(v_direct::text,'NULL');
  END IF;

  -- ===== Caso 5: UPDATE membership_id → re-derive =====
  UPDATE public.resource_rights
     SET holder_membership_id = v_membership_b,
         holder_actor_id = NULL
   WHERE resource_id = v_resource_a;

  SELECT holder_actor_id INTO v_re_derived
    FROM public.resource_rights WHERE resource_id = v_resource_a;
  IF v_re_derived IS DISTINCT FROM v_user_b THEN
    RAISE EXCEPTION '_smoke_r0c1 Caso5: re-derive on UPDATE = % (got %)',
      v_user_b::text, COALESCE(v_re_derived::text,'NULL');
  END IF;

  -- Cleanup
  DELETE FROM public.resource_rights
   WHERE resource_id IN (v_resource_a, v_resource_b, v_resource_c);
  UPDATE public.resources SET archived_at = now()
   WHERE id IN (v_resource_a, v_resource_b, v_resource_c);

  PERFORM set_config('request.jwt.claims', NULL, true);

  RAISE NOTICE '_smoke_r0c1_holder_actor_retrofit passed (5 casos)';
END;
$$;
