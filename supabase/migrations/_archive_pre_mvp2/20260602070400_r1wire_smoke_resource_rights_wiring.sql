-- R.1-WIRE Smoke — _smoke_r1wire_resource_rights_wiring()
--
-- 8 casos requeridos por el plan R.1:
--   1. No quedan resources (no archivados) sin OWN right activo salvo system/unowned.
--   2. create_group_resource crea OWN right.
--   3. create_personal_resource crea resource sin group_id + OWN al user.
--   4. grant VIEW hace aparecer resource en list_actor_resources.
--   5. add_resource_owner actualiza resource_rights.
--   6. end_resource_owner revoca/termina OWN.
--   7. canonical_owner_actor_id sigue sincronizado desde OWN mayor percent.
--   8. Compat views siguen funcionando.

CREATE OR REPLACE FUNCTION public._smoke_r1wire_resource_rights_wiring()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_admin          uuid;  -- user con resources.create + resources.manage_ownership
  v_admin_mship    uuid;  -- su membership
  v_agroup         uuid;  -- su grupo
  v_user_b         uuid;  -- otro person actor
  v_group_res      public.resources%ROWTYPE;
  v_personal_res   public.resources%ROWTYPE;
  v_owner_id       uuid;
  v_right_id       uuid;
  v_count          integer;
  v_canonical      uuid;
BEGIN
  -- ── Setup ──────────────────────────────────────────────────
  SELECT gm.user_id, gm.id, gm.group_id INTO v_admin, v_admin_mship, v_agroup
    FROM public.group_memberships gm
   WHERE gm.status = 'active' AND gm.user_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.group_member_roles gmr
       JOIN public.group_role_permissions grp ON grp.role_id = gmr.role_id
       WHERE gmr.membership_id = gm.id AND grp.permission_key = 'resources.create')
     AND EXISTS (
       SELECT 1 FROM public.group_member_roles gmr
       JOIN public.group_role_permissions grp ON grp.role_id = gmr.role_id
       WHERE gmr.membership_id = gm.id AND grp.permission_key = 'resources.manage_ownership')
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION '_smoke_r1wire setup: no admin-ish membership found';
  END IF;

  SELECT id INTO v_user_b FROM public.actors
   WHERE actor_kind = 'person' AND id <> v_admin LIMIT 1;

  -- ── Caso 1: cero resources activos con canonical owner sin OWN activo ──
  SELECT count(*) INTO v_count
    FROM public.resources r
   WHERE r.archived_at IS NULL
     AND r.canonical_owner_actor_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.resource_rights rr
       WHERE rr.resource_id = r.id
         AND rr.right_kind = 'OWN'
         AND rr.revoked_at IS NULL
         AND rr.expired_at IS NULL
         AND (rr.starts_at IS NULL OR rr.starts_at <= now())
         AND (rr.ends_at IS NULL OR rr.ends_at > now())
     );
  IF v_count > 0 THEN
    RAISE EXCEPTION '_smoke_r1wire Caso1: % resources activos sin OWN right', v_count;
  END IF;

  -- ── Caso 2: create_group_resource crea OWN right ───────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_admin::text)::text, true);
  v_group_res := public.create_group_resource(
    p_group_id := v_agroup,
    p_resource_type := 'asset',
    p_name := '_smoke_r1wire group asset',
    p_metadata := '{}'::jsonb,
    p_client_id := '_smoke_r1wire_' || gen_random_uuid()::text);

  IF NOT public.actor_has_right(v_agroup, v_group_res.id, 'OWN') THEN
    RAISE EXCEPTION '_smoke_r1wire Caso2: create_group_resource no creó OWN right para el group actor';
  END IF;

  -- ── Caso 3: create_personal_resource (sin group_id + OWN al user) ──
  v_personal_res := public.create_personal_resource(
    p_resource_type := 'asset',
    p_name := '_smoke_r1wire personal asset',
    p_metadata := '{"estimated_value": 500, "currency": "MXN"}'::jsonb);

  IF v_personal_res.group_id IS NOT NULL THEN
    RAISE EXCEPTION '_smoke_r1wire Caso3: personal resource tiene group_id';
  END IF;
  IF v_personal_res.canonical_owner_actor_id IS DISTINCT FROM v_admin THEN
    RAISE EXCEPTION '_smoke_r1wire Caso3: canonical owner != caller';
  END IF;
  IF NOT public.actor_has_right(v_admin, v_personal_res.id, 'OWN') THEN
    RAISE EXCEPTION '_smoke_r1wire Caso3: OWN right no creado para el caller';
  END IF;

  -- ── Caso 4: grant VIEW → aparece en list_actor_resources ───
  v_right_id := public.grant_right(
    p_resource_id := v_personal_res.id,
    p_holder_actor_id := v_user_b,
    p_right_kind := 'VIEW');

  -- user_b lista sus propios recursos (self-gating)
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  IF NOT EXISTS (
    SELECT 1 FROM public.list_actor_resources(v_user_b) lr
    WHERE lr.resource_id = v_personal_res.id AND lr.right_kind = 'VIEW'
  ) THEN
    RAISE EXCEPTION '_smoke_r1wire Caso4: VIEW right no aparece en list_actor_resources';
  END IF;

  -- ── Caso 5: add_resource_owner actualiza resource_rights ───
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_admin::text)::text, true);
  v_owner_id := public.add_resource_owner(
    p_resource_id := v_group_res.id,
    p_owner_kind := 'member',
    p_membership_id := v_admin_mship,
    p_ownership_pct := 60,
    p_ownership_role := 'co_owner');

  IF NOT EXISTS (
    SELECT 1 FROM public.resource_rights rr
    WHERE rr.resource_id = v_group_res.id
      AND rr.holder_actor_id = v_admin
      AND rr.right_kind = 'OWN'
      AND rr.revoked_at IS NULL
      AND rr.metadata->>'legacy_owner_id' = v_owner_id::text
  ) THEN
    RAISE EXCEPTION '_smoke_r1wire Caso5: add_resource_owner no sincronizó OWN right';
  END IF;

  -- ── Caso 7 (parte A): canonical sincronizado desde OWN mayor percent ──
  -- El group actor tiene OWN 100 (auto), el member tiene OWN 60 → canonical = group
  SELECT canonical_owner_actor_id INTO v_canonical
    FROM public.resources WHERE id = v_group_res.id;
  IF v_canonical IS DISTINCT FROM v_agroup THEN
    RAISE EXCEPTION '_smoke_r1wire Caso7a: canonical (%) != OWN mayor percent (group %)', v_canonical, v_agroup;
  END IF;

  -- ── Caso 6: end_resource_owner revoca el OWN ───────────────
  PERFORM public.end_resource_owner(p_owner_id := v_owner_id, p_reason := '_smoke_r1wire cleanup');

  IF EXISTS (
    SELECT 1 FROM public.resource_rights rr
    WHERE rr.resource_id = v_group_res.id
      AND rr.holder_actor_id = v_admin
      AND rr.right_kind = 'OWN'
      AND rr.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION '_smoke_r1wire Caso6: end_resource_owner no revocó el OWN right';
  END IF;

  -- ── Caso 7 (parte B): canonical del personal resource = user (su único OWN) ──
  SELECT canonical_owner_actor_id INTO v_canonical
    FROM public.resources WHERE id = v_personal_res.id;
  IF v_canonical IS DISTINCT FROM v_admin THEN
    RAISE EXCEPTION '_smoke_r1wire Caso7b: canonical del personal resource (%) != owner (%)', v_canonical, v_admin;
  END IF;

  -- ── Caso 8: compat views siguen funcionando ────────────────
  -- group_resources view expone el resource grupal (no el personal)
  IF NOT EXISTS (SELECT 1 FROM public.group_resources WHERE id = v_group_res.id) THEN
    RAISE EXCEPTION '_smoke_r1wire Caso8: group_resources view no expone el resource grupal';
  END IF;
  IF EXISTS (SELECT 1 FROM public.group_resources WHERE id = v_personal_res.id) THEN
    RAISE EXCEPTION '_smoke_r1wire Caso8: group_resources view expone el resource personal (group_id NULL)';
  END IF;
  -- group_resource_owners view expone el owner legacy creado en Caso 5
  IF NOT EXISTS (SELECT 1 FROM public.group_resource_owners WHERE id = v_owner_id) THEN
    RAISE EXCEPTION '_smoke_r1wire Caso8: group_resource_owners view no expone el owner';
  END IF;

  -- ── Cleanup ────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims', NULL, true);
  DELETE FROM public.resource_rights
   WHERE resource_id IN (v_group_res.id, v_personal_res.id);
  UPDATE public.resources SET archived_at = now()
   WHERE id IN (v_group_res.id, v_personal_res.id);
  -- resource_owners no se puede borrar (atom_no_delete_guard) — queda ended (residuo aceptado)

  RAISE NOTICE '_smoke_r1wire_resource_rights_wiring passed (8 casos)';
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_r1wire_resource_rights_wiring() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._smoke_r1wire_resource_rights_wiring() IS
  'Smoke R.1-WIRE: 8 casos de wiring de resource_rights como fuente formal (backfill, auto-OWN en creación, dual-write legacy, personal resources, list_actor_resources, canonical sync, compat).';
