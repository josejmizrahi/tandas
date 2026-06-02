-- R.0A.1 MIG 3 — Smoke for forward-sync triggers.
-- 4 casos:
--  Caso 1: insertar auth.users → cadena trigger crea profile → trigger crea actor person
--  Caso 2: insertar group directo → trigger crea actor group
--  Caso 3: re-INSERT del mismo profile/group via ON CONFLICT no duplica actor (idempotencia)
--  Caso 4: zero orphans — todo profile tiene actor, todo group tiene actor (estado global)
--
-- NOTA: esta versión inicial tiene Caso 3 con PERFORM directo a trigger function que
-- requiere contexto NEW (no funciona). Se corrige en la mig siguiente
-- `20260601213642_r0a1_smoke_forward_sync_simplify_caso3.sql`.

CREATE OR REPLACE FUNCTION public._smoke_r0a1_forward_sync()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller_uid    uuid := gen_random_uuid();
  v_owner_uid     uuid := gen_random_uuid();
  v_group_id      uuid := gen_random_uuid();
  v_actor_kind    text;
  v_actor_src     text;
  v_actor_dn      text;
  v_profile_count int;
  v_actors_before int;
  v_actors_after  int;
  v_orphan_profs  int;
  v_orphan_groups int;
BEGIN
  -- Caso 1: auth.users → profile → actor chain
  INSERT INTO auth.users (id) VALUES (v_caller_uid);

  SELECT actor_kind, metadata->>'source', display_name
    INTO v_actor_kind, v_actor_src, v_actor_dn
    FROM public.actors WHERE id = v_caller_uid;

  IF v_actor_kind IS NULL THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso1: actor row not created by profile trigger for uid=%', v_caller_uid;
  END IF;
  IF v_actor_kind != 'person' THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso1: expected kind=person, got %', v_actor_kind;
  END IF;
  IF v_actor_src != 'r0a1_forward_sync_profile' THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso1: expected source=r0a1_forward_sync_profile, got %', v_actor_src;
  END IF;

  -- Caso 2: direct group insert → actor chain
  INSERT INTO auth.users (id) VALUES (v_owner_uid);
  INSERT INTO public.groups (id, name, slug, created_by)
    VALUES (v_group_id, 'R0A1 Smoke Group', 'r0a1-smoke-' || substr(md5(random()::text), 1, 8), v_owner_uid);

  SELECT actor_kind, metadata->>'source', display_name
    INTO v_actor_kind, v_actor_src, v_actor_dn
    FROM public.actors WHERE id = v_group_id;

  IF v_actor_kind IS NULL THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso2: actor row not created by group trigger for id=%', v_group_id;
  END IF;
  IF v_actor_kind != 'group' THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso2: expected kind=group, got %', v_actor_kind;
  END IF;
  IF v_actor_src != 'r0a1_forward_sync_group' THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso2: expected source=r0a1_forward_sync_group, got %', v_actor_src;
  END IF;
  IF v_actor_dn != 'R0A1 Smoke Group' THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso2: expected display_name=R0A1 Smoke Group, got %', v_actor_dn;
  END IF;

  -- Caso 3 (BUG): PERFORM directo a trigger function falla por falta de contexto NEW.
  SELECT count(*) INTO v_actors_before FROM public.actors;
  PERFORM public._sync_actor_from_profile()
    FROM (SELECT v_caller_uid AS id, NULL::text AS display_name, NULL::text AS username) AS faux;
  SELECT count(*) INTO v_actors_after FROM public.actors;
  IF v_actors_after != v_actors_before THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso3: idempotency check failed (% → %)', v_actors_before, v_actors_after;
  END IF;

  -- Caso 4: zero orphans
  SELECT count(*) INTO v_orphan_profs
    FROM public.profiles p
   WHERE NOT EXISTS (SELECT 1 FROM public.actors a WHERE a.id = p.id AND a.actor_kind = 'person');
  IF v_orphan_profs > 0 THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso4: % profiles without actor (orphans)', v_orphan_profs;
  END IF;

  SELECT count(*) INTO v_orphan_groups
    FROM public.groups g
   WHERE NOT EXISTS (SELECT 1 FROM public.actors a WHERE a.id = g.id AND a.actor_kind = 'group');
  IF v_orphan_groups > 0 THEN
    RAISE EXCEPTION '_smoke_r0a1 Caso4: % groups without actor (orphans)', v_orphan_groups;
  END IF;

  -- Cleanup best-effort
  BEGIN
    DELETE FROM public.actors WHERE id IN (v_caller_uid, v_owner_uid, v_group_id);
    DELETE FROM public.groups WHERE id = v_group_id;
    DELETE FROM public.profiles WHERE id IN (v_caller_uid, v_owner_uid);
    DELETE FROM auth.users WHERE id IN (v_caller_uid, v_owner_uid);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE '_smoke_r0a1 cleanup partial: %', SQLERRM;
  END;

  RAISE NOTICE '_smoke_r0a1_forward_sync passed';
END;
$$;
