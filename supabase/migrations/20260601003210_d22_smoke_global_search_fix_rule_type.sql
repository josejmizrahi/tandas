-- D.22 hotfix follow-up: rule_type 'text' is not in the CHECK list
-- (norm | requirement | prohibition | process | principle). Use 'norm'.

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
  v_rule_row     record;
  v_result       jsonb;
  v_count        int;
BEGIN
  SELECT count(*) INTO v_group_count FROM public.groups;
  IF v_group_count > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', v_group_count USING errcode = 'P0001';
  END IF;

  INSERT INTO auth.users (id) VALUES (v_owner_a), (v_owner_b), (v_member_b_uid);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_owner_a::text)::text, true);
  INSERT INTO public.groups (id, name, slug, created_by)
    VALUES (gen_random_uuid(), 'searchtest-a', 'searchtest-a-' || substr(md5(random()::text), 1, 8), v_owner_a)
    RETURNING id INTO v_group_a_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, membership_type, joined_via)
    VALUES (v_group_a_id, v_owner_a, 'active', 'member', 'founder_seed');

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_owner_b::text)::text, true);
  INSERT INTO public.groups (id, name, slug, created_by)
    VALUES (gen_random_uuid(), 'searchtest-b', 'searchtest-b-' || substr(md5(random()::text), 1, 8), v_owner_b)
    RETURNING id INTO v_group_b_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, membership_type, joined_via)
    VALUES (v_group_b_id, v_owner_b, 'active', 'member', 'founder_seed'),
           (v_group_b_id, v_member_b_uid, 'active', 'member', 'admin_add')
    RETURNING id INTO v_member_b_mid;
  INSERT INTO public.group_resources (group_id, resource_type, name, description, created_by, ownership_kind)
    VALUES (v_group_b_id, 'other', 'Quasar Foreign', 'Should not leak to group A', v_owner_b, 'group');

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_owner_a::text)::text, true);
  INSERT INTO public.group_resources (group_id, resource_type, name, description, created_by, ownership_kind)
    VALUES (v_group_a_id, 'other', 'Quasar Hub', 'A galaxy-class device', v_owner_a, 'group')
    RETURNING id INTO v_resource_id;

  INSERT INTO public.group_decisions (group_id, title, body, decision_type, method, legitimacy_source, status, created_by)
    VALUES (v_group_a_id, 'Quasar adoption vote', 'Should we adopt Quasar?', 'proposal', 'majority', 'majority', 'open', v_owner_a)
    RETURNING id INTO v_decision_id;

  -- Use 'norm' (valid rule_type per CHECK constraint)
  SELECT rule_id, version_id INTO v_rule_row
  FROM public.create_text_rule(v_group_a_id, 'Quasar quiet hours', 'No use after 10pm', 'norm', 1);
  v_rule_id := v_rule_row.rule_id;
  UPDATE public.group_rules SET status = 'active' WHERE id = v_rule_id;

  v_result := public.global_search(v_group_a_id, 'q', 25);
  IF jsonb_array_length(v_result) <> 0 THEN
    RAISE EXCEPTION '_smoke_global_search: q=1char expected empty, got %', v_result;
  END IF;

  v_result := public.global_search(v_group_a_id, 'quasar', 25);
  v_count := jsonb_array_length(v_result);
  IF v_count <> 3 THEN
    RAISE EXCEPTION '_smoke_global_search: "quasar" expected 3 hits, got % (%)', v_count, v_result;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result) e WHERE e->>'entity_type' = 'resource' AND (e->>'entity_id')::uuid = v_resource_id) THEN
    RAISE EXCEPTION '_smoke_global_search: resource hit missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result) e WHERE e->>'entity_type' = 'decision' AND (e->>'entity_id')::uuid = v_decision_id) THEN
    RAISE EXCEPTION '_smoke_global_search: decision hit missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result) e WHERE e->>'entity_type' = 'rule' AND (e->>'entity_id')::uuid = v_rule_id) THEN
    RAISE EXCEPTION '_smoke_global_search: rule hit missing';
  END IF;

  v_result := public.global_search(v_group_a_id, 'foreign', 25);
  IF jsonb_array_length(v_result) <> 0 THEN
    RAISE EXCEPTION '_smoke_global_search: cross-tenant leak — "foreign" should be 0 in group A, got %', v_result;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_b_uid::text)::text, true);
  BEGIN
    v_result := public.global_search(v_group_a_id, 'quasar', 25);
    RAISE EXCEPTION '_smoke_global_search: non-member should have been blocked, got %', v_result;
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;

  PERFORM set_config('request.jwt.claims', null, true);
  BEGIN
    PERFORM set_config('session_replication_role', 'replica', true);
    DELETE FROM public.group_rule_versions WHERE rule_id = v_rule_id;
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
