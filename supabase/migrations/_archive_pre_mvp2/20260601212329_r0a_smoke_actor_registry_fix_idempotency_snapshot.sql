-- R.0A MIG 4 (fix) — Smoke idempotency snapshot order.
--
-- Bug in original: `auth.users` insert triggers a `profiles` auto-create
-- (`on_auth_user_created`-style). That new profile lacks an actor row until
-- the first backfill re-run inside Caso 4, so the snapshot showed a legitimate
-- +1 growth that the test misclassified as non-idempotency.
--
-- Fix: in Caso 4, run the backfill ONCE to catch up any test-triggered profiles,
-- THEN snapshot, THEN run again and verify zero diff. That is the actual
-- idempotency contract.

CREATE OR REPLACE FUNCTION public._smoke_r0a_actor_registry()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_profile_count       int;
  v_profile_actor_count int;
  v_group_count         int;
  v_group_actor_count   int;
  v_caller_uid          uuid := gen_random_uuid();
  v_le_id               uuid;
  v_le_actor_kind       text;
  v_le_display_name     text;
  v_le_entity_type      text;
  v_le_count_before     int;
  v_le_count_after      int;
  v_actors_before       int;
  v_actors_after        int;
BEGIN
  -- Caso 1: cada profile tiene actor row (person, mismo UUID)
  SELECT count(*) INTO v_profile_count FROM public.profiles;
  SELECT count(*) INTO v_profile_actor_count
    FROM public.profiles p
    JOIN public.actors a ON a.id = p.id AND a.actor_kind = 'person';
  IF v_profile_count != v_profile_actor_count THEN
    RAISE EXCEPTION '_smoke_r0a Caso1: profiles=% vs person-actors-with-matching-id=%',
      v_profile_count, v_profile_actor_count;
  END IF;

  -- Caso 2: cada group tiene actor row (group, mismo UUID)
  SELECT count(*) INTO v_group_count FROM public.groups;
  SELECT count(*) INTO v_group_actor_count
    FROM public.groups g
    JOIN public.actors a ON a.id = g.id AND a.actor_kind = 'group';
  IF v_group_count != v_group_actor_count THEN
    RAISE EXCEPTION '_smoke_r0a Caso2: groups=% vs group-actors-with-matching-id=%',
      v_group_count, v_group_actor_count;
  END IF;

  -- Caso 3: create_legal_entity crea actor + legal_entity atomicamente
  INSERT INTO auth.users (id) VALUES (v_caller_uid);
  PERFORM set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_caller_uid::text)::text,
                     true);

  SELECT count(*) INTO v_le_count_before FROM public.legal_entities;

  v_le_id := public.create_legal_entity(
    p_display_name := 'R0A Smoke Trust',
    p_entity_type  := 'trust',
    p_tax_id       := 'TEST-001',
    p_jurisdiction := 'MX'
  );

  SELECT count(*) INTO v_le_count_after FROM public.legal_entities;
  IF v_le_count_after != v_le_count_before + 1 THEN
    RAISE EXCEPTION '_smoke_r0a Caso3: legal_entities should grow by 1 (% → %)',
      v_le_count_before, v_le_count_after;
  END IF;

  SELECT a.actor_kind, a.display_name, le.entity_type
    INTO v_le_actor_kind, v_le_display_name, v_le_entity_type
    FROM public.actors a
    JOIN public.legal_entities le ON le.id = a.id
   WHERE a.id = v_le_id;

  IF v_le_actor_kind IS NULL THEN
    RAISE EXCEPTION '_smoke_r0a Caso3: actor row missing for legal entity %', v_le_id;
  END IF;
  IF v_le_actor_kind != 'legal_entity' THEN
    RAISE EXCEPTION '_smoke_r0a Caso3: actor_kind=% (expected legal_entity)', v_le_actor_kind;
  END IF;
  IF v_le_display_name != 'R0A Smoke Trust' THEN
    RAISE EXCEPTION '_smoke_r0a Caso3: display_name=% (expected R0A Smoke Trust)', v_le_display_name;
  END IF;
  IF v_le_entity_type != 'trust' THEN
    RAISE EXCEPTION '_smoke_r0a Caso3: entity_type=% (expected trust)', v_le_entity_type;
  END IF;

  -- Verify update_legal_entity
  PERFORM public.update_legal_entity(p_id := v_le_id, p_display_name := 'R0A Smoke Trust v2');
  SELECT display_name INTO v_le_display_name FROM public.actors WHERE id = v_le_id;
  IF v_le_display_name != 'R0A Smoke Trust v2' THEN
    RAISE EXCEPTION '_smoke_r0a Caso3: update_legal_entity did not sync display_name';
  END IF;

  -- Caso 4: backfill idempotente.
  -- Step A: catch-up run (any profile auto-created by auth triggers earlier
  -- in this smoke gets its actor row now). This is NOT what we're testing —
  -- it's just setup so the snapshot reflects steady state.
  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  SELECT p.id, 'person',
         COALESCE(NULLIF(p.display_name, ''), NULLIF(p.username, ''), '(unnamed person)'),
         jsonb_build_object('source', 'r0a_backfill_catchup')
    FROM public.profiles p
   ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  SELECT g.id, 'group',
         COALESCE(NULLIF(g.name, ''), '(unnamed group)'),
         jsonb_build_object('source', 'r0a_backfill_catchup')
    FROM public.groups g
   ON CONFLICT (id) DO NOTHING;

  -- Step B: snapshot AFTER catch-up.
  SELECT count(*) INTO v_actors_before FROM public.actors;

  -- Step C: second re-run must be a complete no-op.
  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  SELECT p.id, 'person',
         COALESCE(NULLIF(p.display_name, ''), NULLIF(p.username, ''), '(unnamed person)'),
         jsonb_build_object('source', 'r0a_backfill_rerun')
    FROM public.profiles p
   ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  SELECT g.id, 'group',
         COALESCE(NULLIF(g.name, ''), '(unnamed group)'),
         jsonb_build_object('source', 'r0a_backfill_rerun')
    FROM public.groups g
   ON CONFLICT (id) DO NOTHING;

  SELECT count(*) INTO v_actors_after FROM public.actors;
  IF v_actors_before != v_actors_after THEN
    RAISE EXCEPTION '_smoke_r0a Caso4: backfill not idempotent (% → %)',
      v_actors_before, v_actors_after;
  END IF;

  -- Cleanup best-effort
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM set_config('session_replication_role', 'replica', true);
    DELETE FROM public.legal_entities WHERE id = v_le_id;
    DELETE FROM public.actors WHERE id = v_le_id;
    -- Limpiar profile auto-creado por trigger on_auth_user_created (si existe)
    DELETE FROM public.actors WHERE id = v_caller_uid;
    DELETE FROM public.profiles WHERE id = v_caller_uid;
    DELETE FROM auth.users WHERE id = v_caller_uid;
    PERFORM set_config('session_replication_role', 'origin', true);
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  RAISE NOTICE '_smoke_r0a_actor_registry passed (% profiles, % groups, +1 legal_entity create/update verified, idempotent backfill verified)',
    v_profile_count, v_group_count;
END;
$$;
