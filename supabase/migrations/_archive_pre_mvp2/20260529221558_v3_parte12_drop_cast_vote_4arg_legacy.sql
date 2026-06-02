-- PARTE 12 cleanup: drop cast_vote(4-arg) legacy overload.
--
-- Por qué: el 5-arg (con p_weight numeric DEFAULT NULL) matchea cualquier llamada
-- de 4 args, lo que producía 42725 'function not unique' al llamar desde psql
-- con args posicionales. iOS no se ve afectado (encodeOrNil siempre emite
-- p_weight, en JSON null cuando es nil, así que PostgREST routea unambiguo).
--
-- Tras el drop solo queda cast_vote(p_decision_id, p_option_id, p_vote_value,
-- p_reason, p_weight numeric DEFAULT NULL).

DROP FUNCTION IF EXISTS public.cast_vote(uuid, uuid, text, text);
