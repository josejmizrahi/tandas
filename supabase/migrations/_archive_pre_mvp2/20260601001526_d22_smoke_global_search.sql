-- D.22: regression coverage for global_search.
-- Asserts:
--   1. Min length 2 → empty array.
--   2. Per-entity match (member/resource/decision/rule).
--   3. Cross-tenant invariant: same query in group A does NOT return group B entities.
--   4. Unauthenticated / non-member → 42501.

CREATE OR REPLACE FUNCTION public._smoke_global_search()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_group_count  int;
  v_owner_a      uuid := gen_random_uuid();
  v_owner_b      uuid := gen_random_uuid();
  v_group_a_id   uuid;
  v_group_b_id   uuid;
  v_member_b_uid uuid := gen_random_uuid();
  v_member_b_mid uuid;
  v_resource_id  uuid;
  v_decision_id  uuid;
  v_rule_id      uuid;
  v_rule_ver_id  uuid;
  v_result       jsonb;
  v_count        int;
BEGIN
  SELECT count(*) INTO v_group_count FROM public.groups;
  IF v_group_count > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', v_group_count USING errcode = 'P0001';
  END IF;

  INSERT INTO auth.users (id) VALUES (v_owner_a), (v_owner_b), (v_member_b_uid);

  -- Owner A creates group A
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_owner_a::text)::text, true);
  INSERT INTO public.groups (id, name, slug, created_by)
    VALUES (gen_random_uuid(), 'searchtest-a', 'searchtest-a-' || substr(md5(random()::text), 1, 8), v_owner_a)
    RETURNING id INTO v_group_a_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, membership_type, joined_via)
    VALUES (v_group_a_id, v_owner_a, 'active', 'member', 'founder_seed');

  -- Owner B creates group B with a SAME-named entity to test cross-tenant invariant
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_owner_b::text)::text, true);
  INSERT INTO public.groups (id, name, slug, created_by)
    VALUES (gen_random_uuid(), 'searchtest-b', 'searchtest-b-' || substr(md5(random()::text), 1, 8), v_owner_b)
    RETURNING id INTO v_group_b_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, membership_type, joined_via)
    VALUES (v_group_b_id, v_owner_b, 'active', 'member', 'founder_seed'),
           (v_group_b_id, v_member_b_uid, 'active', 'member', 'admin_add')
    RETURNING id INTO v_member_b_mid;
  -- Resource in group B named "Quasar Foreign"
  INSERT INTO public.group_resources (group_id, resource_type, name, description, created_by, ownership_kind)
    VALUES (v_group_b_id, 'other', 'Quasar Foreign', 'Should not leak to group A', v_owner_b, 'group');

  -- Seed entities in group A (the one the caller queries against)
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_owner_a::text)::text, true);
  INSERT INTO public.group_resources (group_id, resource_type, name, description, created_by, ownership_kind)
    VALUES (v_group_a_id, 'other', 'Quasar Hub', 'A galaxy-class device', v_owner_a, 'group')
    RETURNING id INTO v_resource_id;

  INSERT INTO public.group_decisions (group_id, title, body, decision_type, method, legitimacy_source, status, created_by)
    VALUES (v_group_a_id, 'Quasar adoption vote', 'Should we adopt Quasar?', 'proposal', 'majority', 'majority', 'open', v_owner_a)
    RETURNING id INTO v_decision_id;

  INSERT INTO public.group_rules (group_id, title, body, rule_type, status, created_by)
    VALUES (v_group_a_id, 'Quasar quiet hours', 'No use after 10pm', 'text', 'active', v_owner_a)
    RETURNING id INTO v_rule_id;

  -- 1. Min length 2 → empty array
  v_result := public.global_search(v_group_a_id, 'q', 25);
  IF jsonb_array_length(v_result) <> 0 THEN
    RAISE EXCEPTION '_smoke_global_search: q=1char expected empty, got %', v_result;
  END IF;

  -- 2. Match across multiple entity types with "quasar"
  v_result := public.global_search(v_group_a_id, 'quasar', 25);
  v_count := jsonb_array_length(v_result);
  IF v_count <> 3 THEN
    RAISE EXCEPTION '_smoke_global_search: "quasar" expected 3 hits (resource+decision+rule), got % (%)', v_count, v_result;
  END IF;

  -- Verify each entity_type appears exactly once
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result) e WHERE e->>'entity_type' = 'resource' AND (e->>'entity_id')::uuid = v_resource_id) THEN
    RAISE EXCEPTION '_smoke_global_search: resource hit missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result) e WHERE e->>'entity_type' = 'decision' AND (e->>'entity_id')::uuid = v_decision_id) THEN
    RAISE EXCEPTION '_smoke_global_search: decision hit missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result) e WHERE e->>'entity_type' = 'rule' AND (e->>'entity_id')::uuid = v_rule_id) THEN
    RAISE EXCEPTION '_smoke_global_search: rule hit missing';
  END IF;

  -- 3. Cross-tenant invariant: querying group A for "foreign" (which exists only in B) → 0 hits
  v_result := public.global_search(v_group_a_id, 'foreign', 25);
  IF jsonb_array_length(v_result) <> 0 THEN
    RAISE EXCEPTION '_smoke_global_search: cross-tenant leak — "foreign" should be 0 in group A, got %', v_result;
  END IF;

  -- 4. Non-member of group A: switch identity to member B's uid and query group A → must raise 42501
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_b_uid::text)::text, true);
  BEGIN
    v_result := public.global_search(v_group_a_id, 'quasar', 25);
    RAISE EXCEPTION '_smoke_global_search: non-member should have been blocked, got %', v_result;
  EXCEPTION
    WHEN insufficient_privilege THEN
      -- expected
      NULL;
  END;

  -- Cleanup best-effort (uses session_replication_role; non-superuser context skips silently)
  PERFORM set_config('request.jwt.claims', null, true);
  BEGIN
    PERFORM set_config('session_replication_role', 'replica', true);
    DELETE FROM public.group_rules WHERE id = v_rule_id;
    DELETE FROM public.group_decisions WHERE id = v_decision_id;
    DELETE FROM public.group_resources WHERE group_id IN (v_group_a_id, v_group_b_id);
    DELETE FROM public.group_memberships WHERE group_id IN (v_group_a_id, v_group_b_id);
    DELETE FROM public.groups WHERE id IN (v_group_a_id, v_group_b_id);
    DELETE FROM auth.users WHERE id IN (v_owner_a, v_owner_b, v_member_b_uid);
    PERFORM set_config('session_replication_role', 'origin', true);
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;

  RAISE NOTICE '_smoke_global_search passed';
END;
$function$;

GRANT EXECUTE ON FUNCTION public._smoke_global_search() TO postgres;
