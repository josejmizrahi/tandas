-- D.22 FASE B — smoke for action_catalog seed
-- Verifies invariants and seed coverage. Cero side effects.

CREATE OR REPLACE FUNCTION public._smoke_action_catalog_seed()
RETURNS TABLE(check_name text, status text, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_total            integer;
  v_requires_dec     integer;
  v_thresholded      integer;
  v_constitutional   integer;
  v_founder_ovr      integer;
  v_pending_templates integer;
  v_orphan_perm      integer;
  v_orphan_template  integer;
  v_self_only        integer;
  v_distinct_domain  integer;
BEGIN
  -- T1 — Seed cardinality
  SELECT COUNT(*) INTO v_total FROM public.action_catalog;
  IF v_total >= 90 THEN
    check_name := 'T1_seed_count_>=_90'; status := 'PASS'; detail := v_total::text; RETURN NEXT;
  ELSE
    check_name := 'T1_seed_count_>=_90'; status := 'FAIL'; detail := 'got '||v_total||' want >=90'; RETURN NEXT;
  END IF;

  -- T2 — All 17 domains used? (At least the 16 we seeded.)
  SELECT COUNT(DISTINCT domain) INTO v_distinct_domain FROM public.action_catalog;
  IF v_distinct_domain >= 15 THEN
    check_name := 'T2_distinct_domains_>=_15'; status := 'PASS'; detail := v_distinct_domain::text; RETURN NEXT;
  ELSE
    check_name := 'T2_distinct_domains_>=_15'; status := 'FAIL'; detail := v_distinct_domain::text; RETURN NEXT;
  END IF;

  -- T3 — Constitutional rows MUST NOT have founder_can_override.
  PERFORM 1 FROM public.action_catalog WHERE is_constitutional AND founder_can_override;
  IF NOT FOUND THEN
    check_name := 'T3_constitutional_no_founder_override'; status := 'PASS'; detail := 'invariant holds';
  ELSE
    check_name := 'T3_constitutional_no_founder_override'; status := 'FAIL'; detail := 'invariant violated';
  END IF;
  RETURN NEXT;

  -- T4 — Thresholded rows have amount + unit (enforced by check, redundant assert).
  SELECT COUNT(*) INTO v_thresholded
    FROM public.action_catalog
   WHERE has_threshold AND (default_threshold_amount IS NULL OR default_threshold_unit IS NULL);
  IF v_thresholded = 0 THEN
    check_name := 'T4_thresholded_have_amount_and_unit'; status := 'PASS'; detail := '0 violations';
  ELSE
    check_name := 'T4_thresholded_have_amount_and_unit'; status := 'FAIL'; detail := v_thresholded||' violations';
  END IF;
  RETURN NEXT;

  -- T5 — Permission FK integrity (FK enforces; if all good, count NULL perms).
  SELECT COUNT(*) INTO v_orphan_perm
    FROM public.action_catalog ac
   WHERE ac.default_required_permission IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.key = ac.default_required_permission);
  IF v_orphan_perm = 0 THEN
    check_name := 'T5_permission_fk_integrity'; status := 'PASS'; detail := 'all FK valid';
  ELSE
    check_name := 'T5_permission_fk_integrity'; status := 'FAIL'; detail := v_orphan_perm||' orphans';
  END IF;
  RETURN NEXT;

  -- T6 — Template FK integrity.
  SELECT COUNT(*) INTO v_orphan_template
    FROM public.action_catalog ac
   WHERE ac.default_decision_template_key IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.decision_templates_catalog t WHERE t.template_key = ac.default_decision_template_key);
  IF v_orphan_template = 0 THEN
    check_name := 'T6_template_fk_integrity'; status := 'PASS'; detail := 'all FK valid';
  ELSE
    check_name := 'T6_template_fk_integrity'; status := 'FAIL'; detail := v_orphan_template||' orphans';
  END IF;
  RETURN NEXT;

  -- T7 — Pending templates count (queue para FASE D).
  SELECT COUNT(*) INTO v_pending_templates
    FROM public.action_catalog
   WHERE default_requires_decision AND default_decision_template_key IS NULL;
  check_name := 'T7_pending_templates_queue';
  status := CASE WHEN v_pending_templates = 12 THEN 'PASS' ELSE 'INFO' END;
  detail := v_pending_templates||' queued for FASE D';
  RETURN NEXT;

  -- T8 — Founder override count sanity (≥ 50).
  SELECT COUNT(*) INTO v_founder_ovr FROM public.action_catalog WHERE founder_can_override;
  IF v_founder_ovr >= 50 THEN
    check_name := 'T8_founder_override_count_>=_50'; status := 'PASS'; detail := v_founder_ovr::text;
  ELSE
    check_name := 'T8_founder_override_count_>=_50'; status := 'FAIL'; detail := v_founder_ovr::text;
  END IF;
  RETURN NEXT;

  -- T9 — Constitutional count (should be 7).
  SELECT COUNT(*) INTO v_constitutional FROM public.action_catalog WHERE is_constitutional;
  IF v_constitutional = 7 THEN
    check_name := 'T9_constitutional_count_=_7'; status := 'PASS'; detail := v_constitutional::text;
  ELSE
    check_name := 'T9_constitutional_count_=_7'; status := 'FAIL'; detail := 'got '||v_constitutional||' want 7';
  END IF;
  RETURN NEXT;

  -- T10 — Self-only metadata present for identity/inbox/notification rows.
  SELECT COUNT(*) INTO v_self_only
    FROM public.action_catalog
   WHERE domain IN ('identity','inbox','notification')
     AND (metadata->>'self_only')::boolean IS DISTINCT FROM true;
  IF v_self_only = 0 THEN
    check_name := 'T10_self_only_marked_for_identity_inbox_notification'; status := 'PASS'; detail := 'all self_only';
  ELSE
    check_name := 'T10_self_only_marked_for_identity_inbox_notification'; status := 'FAIL'; detail := v_self_only||' missing';
  END IF;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._smoke_action_catalog_seed() FROM PUBLIC;
COMMENT ON FUNCTION public._smoke_action_catalog_seed() IS
  'D.22 FASE B smoke — verifies action_catalog seed cardinality + invariants. T1-T10.';
