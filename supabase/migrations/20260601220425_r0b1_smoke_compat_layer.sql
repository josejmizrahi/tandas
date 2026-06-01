-- R.0B.1 MIG 2 — Smoke for compat layer (Option B audit preservation).
-- 7 casos:
--  1) INSERT directo via compat view → audit marker = 'legacy_view_write'
--  2) SELECT via view returns the new row (transparent)
--  3) UPDATE via view propaga a tabla canónica
--  4) Archive (soft-delete) via view propaga
--  5) Wrapper-style INSERT preserva intent_marker custom
--  6) RPC create_group_resource (que internamente hace INSERT INTO public.group_resources)
--     funciona via compat sin que el wrapper sepa que hay un view en medio
--  7) Owners/Rights compat views accept INSERT (via add_resource_owner / grant_right RPCs)

CREATE OR REPLACE FUNCTION public._smoke_r0b1_compat_layer()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group              uuid;
  v_user               uuid;
  v_resource_id        uuid;
  v_wrapper_id         uuid;
  v_rpc_resource_row   public.resources%ROWTYPE;
  v_audit_marker       text;
  v_resources_before   int;
  v_resources_after    int;
BEGIN
  -- Use existing group + user (no nuevos para no inflar guard counts en otros smokes)
  SELECT id INTO v_group FROM public.groups LIMIT 1;
  SELECT created_by INTO v_user FROM public.groups WHERE id = v_group;
  IF v_group IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION '_smoke_r0b1: no usable group/user found for smoke';
  END IF;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user::text)::text, true);

  -- ===== Caso 1: INSERT directo via compat view → audit marker = legacy_view_write =====
  PERFORM set_config('ruul.resource_create_intent', '', true);
  SELECT count(*) INTO v_resources_before FROM public.resources;

  INSERT INTO public.group_resources
    (group_id, resource_type, name, description, status, visibility,
     ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'document', '_smoke_r0b1 Caso1', 'direct insert via view',
     'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user)
  RETURNING id INTO v_resource_id;

  SELECT count(*) INTO v_resources_after FROM public.resources;
  IF v_resources_after != v_resources_before + 1 THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso1: resources should grow by 1 (% → %)',
      v_resources_before, v_resources_after;
  END IF;

  SELECT intent_marker INTO v_audit_marker
    FROM public.group_resources_direct_insert_audit WHERE resource_id = v_resource_id;
  IF v_audit_marker IS DISTINCT FROM 'legacy_view_write' THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso1: expected marker=legacy_view_write, got %',
      COALESCE(v_audit_marker, 'NULL');
  END IF;

  -- ===== Caso 2: SELECT transparente via view =====
  IF NOT EXISTS (SELECT 1 FROM public.group_resources WHERE id = v_resource_id) THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso2: row not visible via compat view';
  END IF;

  -- ===== Caso 3: UPDATE via view propaga a tabla canónica =====
  UPDATE public.group_resources SET name = '_smoke_r0b1 Caso3 updated' WHERE id = v_resource_id;
  IF NOT EXISTS (SELECT 1 FROM public.resources
                  WHERE id = v_resource_id AND name = '_smoke_r0b1 Caso3 updated') THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso3: UPDATE via view did not propagate';
  END IF;

  -- ===== Caso 4: Archive (canonical soft-delete) via view =====
  UPDATE public.group_resources SET archived_at = now() WHERE id = v_resource_id;
  IF NOT EXISTS (SELECT 1 FROM public.resources
                  WHERE id = v_resource_id AND archived_at IS NOT NULL) THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso4: archive via view did not propagate';
  END IF;

  -- ===== Caso 5: Wrapper-style INSERT preserva intent custom =====
  PERFORM set_config('ruul.resource_create_intent', 'r0b1_smoke_custom_intent', true);
  INSERT INTO public.group_resources
    (group_id, resource_type, name, description, status, visibility,
     ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'document', '_smoke_r0b1 Caso5', 'insert with intent set',
     'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user)
  RETURNING id INTO v_wrapper_id;

  SELECT intent_marker INTO v_audit_marker
    FROM public.group_resources_direct_insert_audit WHERE resource_id = v_wrapper_id;
  IF v_audit_marker IS DISTINCT FROM 'r0b1_smoke_custom_intent' THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso5: wrapper intent should be preserved, got %',
      COALESCE(v_audit_marker, 'NULL');
  END IF;

  -- ===== Caso 6: RPC create_group_resource (la RPC original — DOES NOT KNOW about the view) =====
  -- Its body still says INSERT INTO public.group_resources(...) — that's the whole point of compat.
  PERFORM set_config('ruul.resource_create_intent', '', true);
  v_rpc_resource_row := public.create_group_resource(
    v_group, 'document', '_smoke_r0b1 Caso6', NULL, 'members',
    'group', NULL, NULL, '{}'::jsonb, gen_random_uuid()::text
  );
  IF v_rpc_resource_row.id IS NULL THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso6: create_group_resource returned NULL';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.resources WHERE id = v_rpc_resource_row.id) THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso6: RPC-created resource not in canonical table';
  END IF;

  -- ===== Caso 7: Compat views for owners/rights/capabilities allow SELECT =====
  -- (INSERTs van vía RPCs que ya validamos en R.0A/A1; aquí solo confirmamos SELECT.)
  IF (SELECT count(*) FROM public.group_resource_owners) !=
     (SELECT count(*) FROM public.resource_owners) THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso7a: owners count mismatch view vs table';
  END IF;
  IF (SELECT count(*) FROM public.group_resource_rights) !=
     (SELECT count(*) FROM public.resource_rights) THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso7b: rights count mismatch view vs table';
  END IF;
  IF (SELECT count(*) FROM public.group_resource_capabilities) !=
     (SELECT count(*) FROM public.resource_capabilities) THEN
    RAISE EXCEPTION '_smoke_r0b1 Caso7c: capabilities count mismatch view vs table';
  END IF;

  -- Cleanup (archive en vez de DELETE — append-only guard sobre resource_owners cascade)
  UPDATE public.resources
     SET archived_at = now()
   WHERE id IN (v_resource_id, v_wrapper_id, v_rpc_resource_row.id)
     AND archived_at IS NULL;

  PERFORM set_config('request.jwt.claims', NULL, true);
  PERFORM set_config('ruul.resource_create_intent', '', true);

  RAISE NOTICE '_smoke_r0b1_compat_layer passed (7 casos: legacy_view_write audit + wrapper intent preserved + transparent SELECT/UPDATE/archive + RPC create_group_resource + owners/rights/caps SELECT parity)';
END;
$$;
