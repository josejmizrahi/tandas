-- V3 PARTE 8b fix 2 — REVOKE internal _ fns from authenticated
--
-- El restore en 8b-fix1 fue too greedy: GRANTed a authenticated incluso
-- internal helpers que originalmente eran postgres-only. Críticamente
-- _smoke_money_flow (test fixture que crea rows reales) y _rule_eval_*
-- (engine internals) ahora son authenticated-callable.
--
-- Acción: REVOKE de las 7 internas con sus signatures reales. Siguen
-- siendo invocables desde otras SECURITY DEFINER (corren bajo el
-- definer's context, no del caller).

REVOKE EXECUTE ON FUNCTION public._assert_mandate_authorizes(uuid,uuid,uuid,text,numeric,text,uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._auto_promote_norm_internal(uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._check_norm_promotion_threshold() FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._resolve_authority_path(uuid,uuid,boolean,uuid,text,text,numeric,text,uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._rule_eval_dispatch(jsonb,public.group_events,uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._rule_eval_predicate(jsonb,public.group_events) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._smoke_money_flow() FROM authenticated, public;
