-- PARTE 12 — N.13.3: extender meta-smoke con idempotency pattern check.
--
-- Detecta RPCs SECURITY DEFINER que declaran `p_client_id text` pero NO hacen
-- el memo lookup canónico al inicio. Esta sesión cazó 2:
--   - record_payout (UNIQUE column atrapaba dup pero raise — no idempotent).
--   - record_pool_charge (client_id en metadata jsonb, sin UNIQUE → double-charge).
--
-- Patrón canónico válido (uno de):
--   (a) SELECT por client_id column (record_contribution, record_expense pattern).
--   (b) Delegación a otra RPC canónica con p_client_id propagado (pay_sanction
--       delega a record_settlement).
--
-- N.13.3 considera "OK" si el prosrc contiene cualquiera de:
--   - `client_id = p_client_id` (memo select directo)
--   - `record_settlement(...p_client_id`, `record_expense(...p_client_id`,
--     `record_contribution(...p_client_id`, `record_pool_charge(...p_client_id`,
--     `record_payout(...p_client_id` (delegación a inserter canónico)
--   - `metadata->>'client_id'` (memo via jsonb post-hot-fix).

CREATE OR REPLACE FUNCTION public._smoke_permission_keys_audit()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_unknown_assert int;
  v_unknown_has    int;
  v_no_memo        int;
  v_first_unknown  text;
BEGIN
  WITH perm_callers AS (
    SELECT p.proname,
           (regexp_matches(p.prosrc, 'assert_permission\(\s*[^,]+,\s*''([a-z_\.]+)''', 'g'))[1] AS perm_key
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
  )
  SELECT count(*),
         min(pc.proname || ' → ' || pc.perm_key)
    INTO v_unknown_assert, v_first_unknown
  FROM perm_callers pc
  LEFT JOIN public.permissions pe ON pe.key = pc.perm_key
  WHERE pe.key IS NULL;

  step := 'N.13.1.no_unknown_keys_in_assert_permission';
  ok := v_unknown_assert = 0;
  detail := 'unknown=' || v_unknown_assert
            || COALESCE(' first=' || v_first_unknown, ''); RETURN NEXT;

  WITH perm_callers AS (
    SELECT p.proname,
           (regexp_matches(p.prosrc, 'has_(?:group_)?permission\(\s*[^,]+,\s*''([a-z_\.]+)''', 'g'))[1] AS perm_key
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
  )
  SELECT count(*),
         min(pc.proname || ' → ' || pc.perm_key)
    INTO v_unknown_has, v_first_unknown
  FROM perm_callers pc
  LEFT JOIN public.permissions pe ON pe.key = pc.perm_key
  WHERE pe.key IS NULL;

  step := 'N.13.2.no_unknown_keys_in_has_permission';
  ok := v_unknown_has = 0;
  detail := 'unknown=' || v_unknown_has
            || COALESCE(' first=' || v_first_unknown, ''); RETURN NEXT;

  -- N.13.3 idempotency pattern check
  SELECT count(*), min(p.proname)
    INTO v_no_memo, v_first_unknown
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND pg_get_function_identity_arguments(p.oid) ILIKE '%p_client_id text%'
     -- Falla si NO matchea ninguno de los patrones canónicos:
     AND NOT (
       p.prosrc ~ 'client_id\s*=\s*p_client_id'  -- memo select por column
       OR p.prosrc ~ 'metadata->>''client_id'''  -- memo via jsonb
       OR p.prosrc ~ '(record_settlement|record_expense|record_contribution|record_pool_charge|record_payout)\([^)]*p_client_id'  -- delegation
     );
  step := 'N.13.3.idempotency_pattern_canonical';
  ok := v_no_memo = 0;
  detail := 'no_memo=' || v_no_memo
            || COALESCE(' first=' || v_first_unknown, ''); RETURN NEXT;

  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_permission_keys_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_permission_keys_audit() TO service_role;
