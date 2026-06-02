-- R.1-SEC.4 — REVOKE PUBLIC/anon en write RPCs actor-céntricos
--
-- Hallazgo post-SEC.2 (verificado vía has_function_privilege + advisors):
-- los RPCs de escritura actor-céntricos y my_world_summary conservaban el
-- EXECUTE de PUBLIC que PostgreSQL otorga por default al crear funciones —
-- las migrations R.0 hicieron GRANT a authenticated pero nunca REVOKE FROM PUBLIC,
-- y CREATE OR REPLACE (SEC.2) preserva el ACL existente.
--
-- Mitigante: todos estos RPCs lanzan 28000 si auth.uid() IS NULL, así que anon
-- no puede operar — pero la doctrina R.1-SEC exige defensa en profundidad:
-- "REVOKE EXECUTE FROM anon/PUBLIC donde aplique; GRANT EXECUTE TO authenticated explícito".
--
-- Idempotente (REVOKE/GRANT son idempotentes).

-- Write RPCs universales (hardened en SEC.2)
REVOKE ALL ON FUNCTION public.grant_right(uuid, uuid, text, numeric, text, timestamp with time zone, timestamp with time zone, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.grant_right(uuid, uuid, text, numeric, text, timestamp with time zone, timestamp with time zone, uuid, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.revoke_right(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_right(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.create_actor_relationship(uuid, text, uuid, uuid, timestamp with time zone, timestamp with time zone, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_actor_relationship(uuid, text, uuid, uuid, timestamp with time zone, timestamp with time zone, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.end_actor_relationship(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.end_actor_relationship(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.create_legal_entity(text, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_legal_entity(text, text, text, text, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.update_legal_entity(uuid, text, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_legal_entity(uuid, text, text, text, text, jsonb) TO authenticated, service_role;

-- Context view self-scoped (iOS production RPC) — PUBLIC default nunca revocado en R.0E.2
REVOKE ALL ON FUNCTION public.my_world_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_world_summary() TO authenticated, service_role;

-- ============================================================
-- Verificación inline: ninguno de los RPCs del contrato actor-céntrico
-- debe quedar ejecutable por anon.
-- ============================================================
DO $$
DECLARE
  v_fn   text;
  v_bad  text := '';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.my_world_summary()',
    'public.group_world_summary(uuid)',
    'public.legal_entity_world_summary(uuid)',
    'public.actor_net_worth(uuid)',
    'public.list_actor_resources(uuid)',
    'public.actor_has_right(uuid, uuid, text)',
    'public.has_actor_authority(uuid, text)',
    'public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, uuid, jsonb)',
    'public.revoke_right(uuid)',
    'public.create_actor_relationship(uuid, text, uuid, uuid, timestamptz, timestamptz, jsonb)',
    'public.end_actor_relationship(uuid)',
    'public.list_actor_relationships(uuid, text, boolean)',
    'public.create_personal_resource(text, text, text, text, jsonb, text)',
    'public.create_legal_entity(text, text, text, text, jsonb)',
    'public.update_legal_entity(uuid, text, text, text, text, jsonb)',
    'public.add_legal_entity_controller(uuid, uuid, jsonb)',
    'public.add_legal_entity_beneficiary(uuid, uuid, numeric, jsonb)',
    'public.add_legal_entity_shareholder(uuid, uuid, numeric, jsonb)'
  ] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || v_fn || '; ';
    END IF;
  END LOOP;
  IF v_bad <> '' THEN
    RAISE EXCEPTION 'r1sec4: RPCs todavía ejecutables por anon: %', v_bad;
  END IF;
  RAISE NOTICE 'r1sec4: cero RPCs del contrato actor-céntrico ejecutables por anon';
END $$;
